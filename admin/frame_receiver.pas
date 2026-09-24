unit frame_receiver;

{ TFrameReceiverThread - подключается к rdp_client, проходит аутентификацию и
  принимает FRAME_UPDATE, композируя их в offscreen TBitmap (двойная буферизация:
  форма рисует уже готовый offscreen-битмап на канвас, без мерцания).
  Доступ к offscreen-битмапу из UI-потока (перерисовка) и из этого потока (запись
  новых кадров) защищён общим TCriticalSection (LockBitmap/UnlockBitmap). }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, Graphics, ssockets, sockets,
  rdp_protocol, rdp_crypto, rdp_codec, rdp_winapi;

type
  TConnState = (csConnecting, csConnected, csAuthFailed, csBusy, csDisconnected, csError);

  TAdminLogEvent = procedure(const AMsg: string) of object;
  TAdminStateEvent = procedure(AState: TConnState; const AMsg: string) of object;
  TAdminFrameEvent = procedure of object;
  TAdminStatsEvent = procedure(AFPS, ABitrateKBs: Double; AWidth, AHeight, ALatencyMs: Integer) of object;

  TFrameReceiverThread = class(TThread)
  private
    FHost: string;
    FPort: Word;
    FPassword: string;
    FSock: TInetSocket;
    FSockLock: SyncObjs.TCriticalSection;
    FBitmapLock: SyncObjs.TCriticalSection;
    FOffscreen: TBitmap;
    FVSLeft, FVSTop, FVSWidth, FVSHeight: Integer;

    FOnLog: TAdminLogEvent;
    FOnState: TAdminStateEvent;
    FOnFrame: TAdminFrameEvent;
    FOnStats: TAdminStatsEvent;

    FSyncMsg: string;
    FSyncState: TConnState;
    FSyncFPS, FSyncBitrateKBs: Double;
    FSyncW, FSyncH, FSyncLatency: Integer;

    FPingSentTick: QWord;
    FPingPending: Boolean;
    FLatencyMs: Integer;
    FWindowStartTick: QWord;
    FFramesInWindow: Integer;
    FBytesInWindow: Int64;
    FLastPaintNotifyTick: QWord;

    procedure SyncLog;
    procedure SyncState;
    procedure SyncStats;
    procedure DoLog(const AMsg: string);
    procedure DoState(AState: TConnState; const AMsg: string);
    procedure DoStats;
    procedure MaybeNotifyFrameReady;

    function PerformHandshake(out AState: TConnState; out AErrorMsg: string): Boolean;
    procedure HandleFrameUpdate(const APayload: TBytes);
    procedure MaybeSendPing;
  protected
    procedure Execute; override;
  public
    constructor Create(const AHost: string; APort: Word; const APassword: string;
      AOnLog: TAdminLogEvent; AOnState: TAdminStateEvent; AOnFrame: TAdminFrameEvent;
      AOnStats: TAdminStatsEvent);
    destructor Destroy; override;

    // Принудительно закрывает сокет, чтобы разблокировать поток в блокирующем Read.
    procedure ForceDisconnect;

    // Потокобезопасная отправка команды ввода (вызывается из UI-потока) - использует ту же
    // блокировку, что и периодический PING из этого потока, чтобы пакеты не перемешивались,
    // и тот же барьер, что и освобождение сокета, чтобы не писать в уже закрытый FSock.
    procedure SendPacket(APacketType: Byte; const APayload: TBytes);

    procedure LockBitmap;
    procedure UnlockBitmap;

    property Offscreen: TBitmap read FOffscreen;
    property VirtualLeft: Integer read FVSLeft;
    property VirtualTop: Integer read FVSTop;
    property VirtualWidth: Integer read FVSWidth;
    property VirtualHeight: Integer read FVSHeight;
  end;

implementation

const
  PING_INTERVAL_MS = 1000;
  // Ограничиваем частоту запросов на перерисовку UI (~30 Гц), а не частоту кадров с сети -
  // так "при отставании" сети от экрана лишние промежуточные кадры просто не порождают
  // лишних перерисовок (перерисовывается уже актуальный offscreen-битмап).
  PAINT_NOTIFY_INTERVAL_MS = 33;

{ TFrameReceiverThread }

constructor TFrameReceiverThread.Create(const AHost: string; APort: Word; const APassword: string;
  AOnLog: TAdminLogEvent; AOnState: TAdminStateEvent; AOnFrame: TAdminFrameEvent;
  AOnStats: TAdminStatsEvent);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FHost := AHost;
  FPort := APort;
  FPassword := APassword;
  FOnLog := AOnLog;
  FOnState := AOnState;
  FOnFrame := AOnFrame;
  FOnStats := AOnStats;
  FBitmapLock := SyncObjs.TCriticalSection.Create;
  FSockLock := SyncObjs.TCriticalSection.Create;
  FOffscreen := TBitmap.Create;
  FOffscreen.PixelFormat := pf32bit;
end;

destructor TFrameReceiverThread.Destroy;
begin
  FOffscreen.Free;
  FBitmapLock.Free;
  FSockLock.Free;
  inherited Destroy;
end;

procedure TFrameReceiverThread.LockBitmap;
begin
  FBitmapLock.Enter;
end;

procedure TFrameReceiverThread.UnlockBitmap;
begin
  FBitmapLock.Leave;
end;

procedure TFrameReceiverThread.SendPacket(APacketType: Byte; const APayload: TBytes);
begin
  FSockLock.Enter;
  try
    if Assigned(FSock) then
      try
        WritePacket(FSock, APacketType, APayload);
      except
        // соединение могло разорваться параллельно - приёмный цикл сам это обнаружит и сообщит
      end;
  finally
    FSockLock.Leave;
  end;
end;

procedure TFrameReceiverThread.SyncLog;
begin
  if Assigned(FOnLog) then FOnLog(FSyncMsg);
end;

procedure TFrameReceiverThread.SyncState;
begin
  if Assigned(FOnState) then FOnState(FSyncState, FSyncMsg);
end;

procedure TFrameReceiverThread.SyncStats;
begin
  if Assigned(FOnStats) then FOnStats(FSyncFPS, FSyncBitrateKBs, FSyncW, FSyncH, FSyncLatency);
end;

procedure TFrameReceiverThread.DoLog(const AMsg: string);
begin
  FSyncMsg := AMsg;
  Synchronize(@SyncLog);
end;

procedure TFrameReceiverThread.DoState(AState: TConnState; const AMsg: string);
begin
  FSyncState := AState;
  FSyncMsg := AMsg;
  Synchronize(@SyncState);
end;

procedure TFrameReceiverThread.DoStats;
begin
  FSyncFPS := FFramesInWindow;
  FSyncBitrateKBs := FBytesInWindow / 1024.0;
  FSyncW := FVSWidth;
  FSyncH := FVSHeight;
  FSyncLatency := FLatencyMs;
  Queue(@SyncStats);
end;

procedure TFrameReceiverThread.MaybeNotifyFrameReady;
var
  Now: QWord;
begin
  Now := GetTickCount64;
  if (Now - FLastPaintNotifyTick) < PAINT_NOTIFY_INTERVAL_MS then
    Exit;
  FLastPaintNotifyTick := Now;
  if Assigned(FOnFrame) then
    Queue(FOnFrame); // TThreadMethod без параметров - можно передавать напрямую в Queue
end;

function TFrameReceiverThread.PerformHandshake(out AState: TConnState; out AErrorMsg: string): Boolean;
var
  Hello: TBytes;
  PT: Byte;
  Salt, Payload: TBytes;
  Hash: TSHA256Digest;
begin
  Result := False;
  AErrorMsg := '';
  AState := csError;

  SetLength(Hello, 5);
  Hello[0] := RDP_MAGIC[0]; Hello[1] := RDP_MAGIC[1];
  Hello[2] := RDP_MAGIC[2]; Hello[3] := RDP_MAGIC[3];
  Hello[4] := RDP_PROTOCOL_VERSION;
  WritePacket(FSock, PT_HELLO, Hello);

  if not ReadPacket(FSock, PT, Payload) then
  begin
    AErrorMsg := 'соединение закрыто до ответа на HELLO';
    Exit;
  end;

  if PT = PT_BUSY then
  begin
    AState := csBusy;
    AErrorMsg := 'на клиенте уже есть активное подключение';
    Exit;
  end;
  if PT <> PT_SALT then
  begin
    AErrorMsg := Format('ожидался SALT, получен $%.2x', [PT]);
    Exit;
  end;
  Salt := Payload;

  Hash := SHA256PasswordSalt(FPassword, Salt);
  WritePacket(FSock, PT_AUTH_RESP, DigestToBytes(Hash));

  if not ReadPacket(FSock, PT, Payload) then
  begin
    AErrorMsg := 'соединение закрыто до ответа на AUTH_RESP';
    Exit;
  end;
  if PT = PT_AUTH_FAIL then
  begin
    AState := csAuthFailed;
    AErrorMsg := 'неверный пароль';
    Exit;
  end;
  if PT <> PT_AUTH_OK then
  begin
    AErrorMsg := Format('ожидался AUTH_OK, получен $%.2x', [PT]);
    Exit;
  end;

  AState := csConnected;
  Result := True;
end;

procedure TFrameReceiverThread.HandleFrameUpdate(const APayload: TBytes);
var
  Hdr: TFrameHeader;
  PixelData, RawPixels: TBytes;
  ExpectedRaw: Integer;
  LX, LY: Integer;
begin
  if Length(APayload) < 21 then
    Exit; // битый пакет - молча игнорируем кадр, соединение не рвём
  Hdr := DecodeFrameHeader(Copy(APayload, 0, 21));
  PixelData := Copy(APayload, 21, Length(APayload) - 21);

  // Защита от рассинхронизации TCP-потока (например, из-за старой версии клиента без
  // исправления частичной записи в сокет - см. WriteExact в rdp_protocol.pas): считаем
  // размер в Int64, чтобы само умножение не могло переполниться, и заранее отбрасываем
  // заведомо бессмысленные W/H. Если заголовок кадра бессмысленный, значит byte-граница
  // пакета потеряна и весь дальнейший поток на этом соединении уже не восстановить -
  // поэтому не "пропускаем кадр", а прерываем сессию понятным сообщением.
  if (Hdr.W <= 0) or (Hdr.H <= 0) or (Int64(Hdr.W) * Int64(Hdr.H) > 64 * 1024 * 1024) then
    raise Exception.CreateFmt(
      'обнаружена рассинхронизация потока данных (W=%d, H=%d) - вероятно, на клиенте ' +
      'и админе разные версии приложения; переподключитесь после обновления rdp_client.exe',
      [Hdr.W, Hdr.H]);
  ExpectedRaw := Hdr.W * Hdr.H * 4;

  try
    case Hdr.Codec of
      CODEC_RAW:
        RawPixels := PixelData; // уже сырые BGRA
      CODEC_RLE:
        RawPixels := RLEDecode(PixelData, Hdr.W * Hdr.H);
      CODEC_ZLIB:
        RawPixels := ZlibDecompressBytes(PixelData, ExpectedRaw);
    else
      Exit; // неизвестный кодек - пропускаем кадр, не рвём соединение
    end;
  except
    Exit; // битые/повреждённые данные кадра - пропускаем, ждём следующий
  end;

  if Length(RawPixels) <> ExpectedRaw then
    Exit;

  LockBitmap;
  try
    // Первый кадр сессии - он всегда полный (см. TScreenCapturer.Reset на стороне клиента) -
    // задаёт систему координат и размер offscreen-битмапа под виртуальный экран клиента.
    // Смена разрешения посреди сессии не поддерживается (известное ограничение, см. README).
    if FVSWidth = 0 then
    begin
      FVSLeft := Hdr.X;
      FVSTop := Hdr.Y;
      FVSWidth := Hdr.W;
      FVSHeight := Hdr.H;
      FOffscreen.SetSize(FVSWidth, FVSHeight);
    end;

    LX := Hdr.X - FVSLeft;
    LY := Hdr.Y - FVSTop;
    if (LX >= 0) and (LY >= 0) and (LX + Hdr.W <= FOffscreen.Width) and (LY + Hdr.H <= FOffscreen.Height) then
      BlitRawBGRA(FOffscreen.Canvas.Handle, LX, LY, Hdr.W, Hdr.H, RawPixels);
  finally
    UnlockBitmap;
  end;

  Inc(FFramesInWindow);
  FBytesInWindow := FBytesInWindow + Length(APayload);
  MaybeNotifyFrameReady;
end;

procedure TFrameReceiverThread.MaybeSendPing;
var
  Empty: TBytes;
begin
  if FPingPending then Exit;
  if (GetTickCount64 - FPingSentTick) < PING_INTERVAL_MS then Exit;
  SetLength(Empty, 0);
  SendPacket(PT_PING, Empty);
  FPingSentTick := GetTickCount64;
  FPingPending := True;
end;

procedure TFrameReceiverThread.Execute;
var
  St: TConnState;
  ErrMsg: string;
  PT: Byte;
  Payload: TBytes;
begin
  DoState(csConnecting, Format('Подключение к %s:%d...', [FHost, FPort]));
  try
    FSock := TInetSocket.Create(FHost, FPort);
  except
    on E: Exception do
    begin
      DoState(csError, 'Не удалось подключиться: ' + E.Message);
      Exit;
    end;
  end;

  try
    try
      FSock.IOTimeout := 10000;
      if not PerformHandshake(St, ErrMsg) then
      begin
        DoState(St, ErrMsg);
        Exit;
      end;
      DoState(csConnected, 'Подключено');

      FSock.IOTimeout := 0;
      FWindowStartTick := GetTickCount64;
      FPingSentTick := FWindowStartTick;
      FLastPaintNotifyTick := 0;

      while not Terminated do
      begin
        MaybeSendPing;

        if not ReadPacket(FSock, PT, Payload) then
          Break;

        case PT of
          PT_FRAME_UPDATE:
            HandleFrameUpdate(Payload);
          PT_PONG:
            begin
              if FPingPending then
              begin
                FLatencyMs := Integer(GetTickCount64 - FPingSentTick);
                FPingPending := False;
              end;
            end;
          PT_DISCONNECT:
            Break;
        end;

        if (GetTickCount64 - FWindowStartTick) >= 1000 then
        begin
          DoStats;
          FFramesInWindow := 0;
          FBytesInWindow := 0;
          FWindowStartTick := GetTickCount64;
        end;
      end;

      if not Terminated then
        DoState(csDisconnected, 'Соединение закрыто удалённой стороной');
    except
      on E: Exception do
        DoState(csError, 'Ошибка соединения: ' + E.Message);
    end;
  finally
    FSockLock.Enter;
    try
      FreeAndNil(FSock);
    finally
      FSockLock.Leave;
    end;
  end;
end;

procedure TFrameReceiverThread.ForceDisconnect;
begin
  Terminate;
  // TSocketStream не даёт публичного Shutdown, поэтому закрываем хендл сокета напрямую -
  // это разблокирует поток, застрявший в блокирующем Read (см. server_threads.ForceDisconnect).
  if Assigned(FSock) then
    try
      sockets.CloseSocket(Longint(FSock.Handle));
    except
      // сокет уже мог быть закрыт другой стороной - игнорируем
    end;
end;

end.
