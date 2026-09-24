unit server_threads;

{ Сетевой сервер клиента (rdp_client.exe) поверх fcl-net (ssockets):
  - TRdpListenerThread - слушает порт, принимает подключения;
  - TRdpConnectionThread - обслуживает одно подключение: рукопожатие/аутентификация,
    затем параллельно запускает TFrameSenderThread (передача экрана) и сам ведёт
    приём команд (PING/PONG и заготовка под MOUSE_*/KEY_* - инъекция ввода будет
    подключена на этапе 6);
  - TFrameSenderThread - захватывает экран (screen_capture.TScreenCapturer) и
    отправляет FRAME_UPDATE с ограничением по FPS.
  Оба потока сессии пишут в один TSocketStream, поэтому запись защищена общим
  SyncObjs.TCriticalSection (FWriteLock), иначе заголовок и полезная нагрузка разных пакетов
  могли бы перемешаться при одновременной записи из двух потоков.
  Разрешено только одно активное подключение одновременно (TSessionGate); остальным
  отправляется BUSY и соединение закрывается. }

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, SyncObjs, ssockets, sockets,
  rdp_protocol, rdp_crypto, rdp_codec, rdp_winapi, screen_capture;

type
  TRdpLogEvent = procedure(const AMsg: string) of object;

  { Гарантирует, что активна не более чем одна сессия одновременно. }
  TSessionGate = class
  private
    FCS: SyncObjs.TCriticalSection;
    FBusy: Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function TryAcquire: Boolean;
    procedure Release;
  end;

  { Захватывает экран и передаёт FRAME_UPDATE с ограничением ~15 FPS
    (интервал между кадрами не меньше FRAME_INTERVAL_MS). Кодек - пока только RAW,
    RLE/zlib подключаются на этапе 5. }
  TFrameSenderThread = class(TThread)
  private
    FStream: TSocketStream;
    FWriteLock: SyncObjs.TCriticalSection;
    FOnLog: TRdpLogEvent;
    FSyncMsg: string;
    FCapturer: TScreenCapturer;
    procedure SyncLog;
    procedure DoLog(const AMsg: string);
  protected
    procedure Execute; override;
  public
    constructor Create(AStream: TSocketStream; AWriteLock: SyncObjs.TCriticalSection; AOnLog: TRdpLogEvent);
    destructor Destroy; override;
  end;

  TRdpConnectionThread = class(TThread)
  private
    FStream: TSocketStream;
    FGate: TSessionGate;
    FPassword: string;
    FRemoteIP: string;
    FOnLog: TRdpLogEvent;
    FSyncMsg: string;
    FWriteLock: SyncObjs.TCriticalSection;
    FFrameSender: TFrameSenderThread;
    procedure SyncLog;
    procedure DoLog(const AMsg: string);
    // Возвращает True при успешной аутентификации. AErrorMsg заполняется при неудаче.
    function PerformHandshake(out AErrorMsg: string): Boolean;
    procedure RunSessionLoop;
  protected
    procedure Execute; override;
  public
    constructor Create(AStream: TSocketStream; AGate: TSessionGate;
      const APassword, ARemoteIP: string; AOnLog: TRdpLogEvent);
    // Принудительно закрывает сокет, чтобы разблокировать поток, застрявший в блокирующем Read.
    procedure ForceDisconnect;
  end;

  TRdpListenerThread = class(TThread)
  private
    FServer: TInetServer;
    FPort: Word;
    FPassword: string;
    FGate: TSessionGate;
    FOnLog: TRdpLogEvent;
    FCS: SyncObjs.TCriticalSection;
    FActiveConn: TRdpConnectionThread;
    FSyncMsg: string;
    procedure SyncLog;
    procedure DoLog(const AMsg: string);
    procedure HandleConnect(Sender: TObject; AData: TSocketStream);
    procedure HandleConnTerminate(Sender: TObject);
  protected
    procedure Execute; override;
  public
    // Bind выполняется уже в конструкторе (в потоке вызывающего/UI), поэтому ошибка
    // "порт занят" возвращается сразу же, а не теряется где-то в фоновом потоке.
    constructor Create(APort: Word; const APassword: string; AOnLog: TRdpLogEvent);
    destructor Destroy; override;
    procedure RequestStop;
  end;

implementation

{ TSessionGate }

constructor TSessionGate.Create;
begin
  inherited Create;
  FCS := SyncObjs.TCriticalSection.Create;
  FBusy := False;
end;

destructor TSessionGate.Destroy;
begin
  FCS.Free;
  inherited Destroy;
end;

function TSessionGate.TryAcquire: Boolean;
begin
  FCS.Enter;
  try
    Result := not FBusy;
    if Result then
      FBusy := True;
  finally
    FCS.Leave;
  end;
end;

procedure TSessionGate.Release;
begin
  FCS.Enter;
  try
    FBusy := False;
  finally
    FCS.Leave;
  end;
end;

{ TFrameSenderThread }

const
  // ТЗ требует одновременно "максимум 15 FPS" и "не чаще, чем раз в 30мс".
  // 1000/15 ≈ 67мс, что само по себе больше 30мс, поэтому единственный интервал
  // FRAME_INTERVAL_MS удовлетворяет обоим ограничениям сразу.
  TARGET_FPS = 15;
  FRAME_INTERVAL_MS = 1000 div TARGET_FPS;

constructor TFrameSenderThread.Create(AStream: TSocketStream; AWriteLock: SyncObjs.TCriticalSection; AOnLog: TRdpLogEvent);
begin
  inherited Create(True);
  FreeOnTerminate := False; // жизненным циклом управляет TRdpConnectionThread
  FStream := AStream;
  FWriteLock := AWriteLock;
  FOnLog := AOnLog;
  FCapturer := TScreenCapturer.Create;
end;

destructor TFrameSenderThread.Destroy;
begin
  FCapturer.Free;
  inherited Destroy;
end;

procedure TFrameSenderThread.SyncLog;
begin
  if Assigned(FOnLog) then
    FOnLog(FSyncMsg);
end;

procedure TFrameSenderThread.DoLog(const AMsg: string);
begin
  FSyncMsg := AMsg;
  Synchronize(@SyncLog);
end;

// Выбирает наиболее компактный кодек из RAW/RLE/zlib для данного кадра.
// Если RLE или zlib не выигрывают по размеру (или дали сбой) - остаёмся на предыдущем
// лучшем варианте; RAW как отправная точка гарантированно всегда доступен.
procedure ChooseBestCodec(const APixels: TBytes; APixelCount: Integer;
  out ACodec: Byte; out AEncoded: TBytes);
var
  Candidate: TBytes;
begin
  ACodec := CODEC_RAW;
  AEncoded := APixels;

  try
    Candidate := RLEEncode(APixels, APixelCount);
    if Length(Candidate) < Length(AEncoded) then
    begin
      ACodec := CODEC_RLE;
      AEncoded := Candidate;
    end;
  except
    // RLE не удался - остаёмся на текущем лучшем варианте
  end;

  try
    Candidate := ZlibCompressBytes(APixels);
    if Length(Candidate) < Length(AEncoded) then
    begin
      ACodec := CODEC_ZLIB;
      AEncoded := Candidate;
    end;
  except
    // zlib не удался - остаёмся на текущем лучшем варианте
  end;
end;

procedure TFrameSenderThread.Execute;
var
  LastTick: QWord;
  X, Y, W, H: Integer;
  Pixels, HeaderBytes, EncodedPixels, Payload: TBytes;
  Header: TFrameHeader;
  Codec: Byte;
  IsFirstFrame: Boolean;
begin
  FCapturer.Reset; // новая сессия - первый кадр должен уйти полностью
  LastTick := 0;
  IsFirstFrame := True;
  while not Terminated do
  begin
    if (GetTickCount64 - LastTick) < FRAME_INTERVAL_MS then
    begin
      Sleep(5); // короткий сон, чтобы часто проверять Terminated, а не спать одним блоком
      Continue;
    end;
    LastTick := GetTickCount64;
    try
      if FCapturer.CaptureIfChanged(X, Y, W, H, Pixels) then
      begin
        // Первый (всегда полноэкранный) кадр отправляем как RAW без промедления -
        // RLE+zlib на ~4K-экране считаются заметное время, а до первой картинки у
        // админа не должно быть задержки. Дальше, для более мелких дозагрузок,
        // уже выбираем оптимальный кодек.
        if IsFirstFrame then
        begin
          Codec := CODEC_RAW;
          EncodedPixels := Pixels;
          IsFirstFrame := False;
        end
        else
          ChooseBestCodec(Pixels, W * H, Codec, EncodedPixels);

        Header.X := X;
        Header.Y := Y;
        Header.W := W;
        Header.H := H;
        Header.CompressedSize := UInt32(Length(EncodedPixels));
        Header.Codec := Codec;
        HeaderBytes := EncodeFrameHeader(Header);
        Payload := ConcatBytes(HeaderBytes, EncodedPixels);

        FWriteLock.Enter;
        try
          WritePacket(FStream, PT_FRAME_UPDATE, Payload);
        finally
          FWriteLock.Leave;
        end;
      end;
    except
      on E: Exception do
      begin
        DoLog('Остановка передачи экрана: ' + E.Message);
        Terminate;
      end;
    end;
  end;
end;

{ TRdpConnectionThread }

constructor TRdpConnectionThread.Create(AStream: TSocketStream; AGate: TSessionGate;
  const APassword, ARemoteIP: string; AOnLog: TRdpLogEvent);
begin
  inherited Create(True); // CreateSuspended - запускаем явно через Start после настройки полей
  // FreeOnTerminate=True: поток сам освобождает себя после завершения Execute.
  // Важно НЕ вызывать WaitFor/Free для этого потока из его же OnTerminate (вызывается
  // через Synchronize изнутри этого же потока) - это гарантированный deadlock
  // (поток ждёт возврата из Synchronize, а обработчик ждёт завершения потока).
  FreeOnTerminate := True;
  FStream := AStream;
  FGate := AGate;
  FPassword := APassword;
  FRemoteIP := ARemoteIP;
  FOnLog := AOnLog;
  FWriteLock := SyncObjs.TCriticalSection.Create;
  FFrameSender := nil;
end;

procedure TRdpConnectionThread.SyncLog;
begin
  if Assigned(FOnLog) then
    FOnLog(FSyncMsg);
end;

procedure TRdpConnectionThread.DoLog(const AMsg: string);
begin
  FSyncMsg := AMsg;
  Synchronize(@SyncLog);
end;

function TRdpConnectionThread.PerformHandshake(out AErrorMsg: string): Boolean;
var
  PT: Byte;
  Payload, Salt: TBytes;
  ExpectedHash, GotHash: TSHA256Digest;
begin
  Result := False;
  AErrorMsg := '';

  // 1. Ожидаем HELLO: payload = magic(4 байта) + версия протокола(1 байт).
  if not ReadPacket(FStream, PT, Payload) then
  begin
    AErrorMsg := 'соединение закрыто до HELLO';
    Exit;
  end;
  if PT <> PT_HELLO then
  begin
    AErrorMsg := Format('ожидался HELLO, получен $%.2x', [PT]);
    Exit;
  end;
  if (Length(Payload) < 5) or
     (Payload[0] <> RDP_MAGIC[0]) or (Payload[1] <> RDP_MAGIC[1]) or
     (Payload[2] <> RDP_MAGIC[2]) or (Payload[3] <> RDP_MAGIC[3]) then
  begin
    AErrorMsg := 'некорректная сигнатура протокола (magic)';
    Exit;
  end;
  // Payload[4] - версия протокола; в текущей версии не влияет на ветвление,
  // зарезервирована под будущее шифрование канала (см. README).

  // 2. Отправляем соль.
  Salt := GenerateRandomBytes(RDP_SALT_SIZE);
  WritePacket(FStream, PT_SALT, Salt);

  // 3. Ожидаем AUTH_RESP = SHA-256(пароль + соль).
  if not ReadPacket(FStream, PT, Payload) then
  begin
    AErrorMsg := 'соединение закрыто до AUTH_RESP';
    Exit;
  end;
  if PT <> PT_AUTH_RESP then
  begin
    AErrorMsg := Format('ожидался AUTH_RESP, получен $%.2x', [PT]);
    Exit;
  end;
  if Length(Payload) <> RDP_HASH_SIZE then
  begin
    AErrorMsg := 'некорректная длина хэша в AUTH_RESP';
    Exit;
  end;

  ExpectedHash := SHA256PasswordSalt(FPassword, Salt);
  GotHash := BytesToDigest(Payload);
  if not DigestsEqual(ExpectedHash, GotHash) then
  begin
    WriteEmptyPacket(FStream, PT_AUTH_FAIL);
    AErrorMsg := 'неверный пароль';
    Exit;
  end;

  WriteEmptyPacket(FStream, PT_AUTH_OK);
  Result := True;
end;

procedure TRdpConnectionThread.RunSessionLoop;
var
  PT: Byte;
  Payload: TBytes;
  MM: TMouseMoveMsg;
  MB: TMouseBtnMsg;
  MW: TMouseWheelMsg;
  KM: TKeyMsg;
  KC: UTF8String;
  WS: UnicodeString;
  i: Integer;
begin
  // Таймаут снят на время сессии: простой соединения не означает обрыв,
  // отслеживание "живости" соединения выполняется через PING/PONG на стороне админа.
  FStream.IOTimeout := 0;
  while not Terminated do
  begin
    if not ReadPacket(FStream, PT, Payload) then
      Break; // штатное закрытие соединения удалённой стороной
    case PT of
      PT_PING:
        begin
          FWriteLock.Enter;
          try
            WriteEmptyPacket(FStream, PT_PONG);
          finally
            FWriteLock.Leave;
          end;
        end;
      PT_DISCONNECT:
        Break;
      PT_SAS:
        try
          if TrySendCtrlAltDel then
            DoLog('Ctrl+Alt+Del: запрос на SendSAS отправлен')
          else
            DoLog('Ctrl+Alt+Del: SendSAS недоступен (нет sas.dll или политики SoftwareSASGeneration)');
        except
          on E: Exception do
            DoLog('Ошибка Ctrl+Alt+Del: ' + E.Message);
        end;
      PT_MOUSE_MOVE, PT_MOUSE_BTN, PT_MOUSE_WHEEL, PT_KEY_DOWN, PT_KEY_UP, PT_KEY_CHAR:
        try
          case PT of
            PT_MOUSE_MOVE:
              begin
                MM := DecodeMouseMove(Payload);
                InputSendMouseMove(MM.X, MM.Y);
              end;
            PT_MOUSE_BTN:
              begin
                MB := DecodeMouseBtn(Payload);
                InputSendMouseButton(MB.Btn, MB.Down <> 0);
              end;
            PT_MOUSE_WHEEL:
              begin
                MW := DecodeMouseWheel(Payload);
                InputSendMouseWheel(MW.Delta);
              end;
            PT_KEY_DOWN:
              begin
                KM := DecodeKey(Payload);
                InputSendKey(KM.VK, True);
              end;
            PT_KEY_UP:
              begin
                KM := DecodeKey(Payload);
                InputSendKey(KM.VK, False);
              end;
            PT_KEY_CHAR:
              begin
                KC := DecodeKeyChar(Payload);
                // UTF8String -> UnicodeString: неявное преобразование через кодовую
                // страницу RTL (UTF8String помечена как CP_UTF8), без сторонних модулей.
                WS := UnicodeString(KC);
                for i := 1 to Length(WS) do
                  InputSendUnicodeChar(WS[i]);
              end;
          end;
        except
          on E: Exception do
            DoLog('Ошибка инъекции ввода: ' + E.Message);
        end;
    end;
  end;
end;

procedure TRdpConnectionThread.Execute;
var
  ErrMsg: string;
begin
  try
    try
      FStream.IOTimeout := 10000; // 10с на весь handshake - защита от зависших/некорректных клиентов
      DoLog(Format('Подключение от %s', [FRemoteIP]));
      if PerformHandshake(ErrMsg) then
      begin
        DoLog(Format('Аутентификация успешна: %s', [FRemoteIP]));
        FFrameSender := TFrameSenderThread.Create(FStream, FWriteLock, FOnLog);
        FFrameSender.Start;
        try
          RunSessionLoop;
        finally
          FFrameSender.Terminate;
          FFrameSender.WaitFor;
          FreeAndNil(FFrameSender);
        end;
        DoLog(Format('Отключение: %s', [FRemoteIP]));
      end
      else
        DoLog(Format('Аутентификация отклонена (%s): %s', [FRemoteIP, ErrMsg]));
    except
      on E: Exception do
        DoLog(Format('Ошибка соединения (%s): %s', [FRemoteIP, E.Message]));
    end;
  finally
    FGate.Release;
    FreeAndNil(FStream);
    FWriteLock.Free;
  end;
end;

procedure TRdpConnectionThread.ForceDisconnect;
begin
  Terminate;
  if Assigned(FFrameSender) then
    FFrameSender.Terminate;
  if Assigned(FStream) then
    try
      sockets.CloseSocket(Longint(FStream.Handle));
    except
      // сокет уже мог быть закрыт другой стороной - игнорируем
    end;
end;

{ TRdpListenerThread }

constructor TRdpListenerThread.Create(APort: Word; const APassword: string; AOnLog: TRdpLogEvent);
begin
  inherited Create(True);
  FreeOnTerminate := False;
  FPort := APort;
  FPassword := APassword;
  FOnLog := AOnLog;
  FGate := TSessionGate.Create;
  FCS := SyncObjs.TCriticalSection.Create;
  FActiveConn := nil;

  // Bind выполняется здесь же (ещё до Start потока), чтобы ошибка "порт занят"
  // всплыла сразу в обработчике кнопки "Старт", а не потерялась в фоновом потоке.
  FServer := TInetServer.Create(FPort);
  FServer.ReuseAddress := True;
  FServer.Bind;
end;

destructor TRdpListenerThread.Destroy;
begin
  FreeAndNil(FServer);
  FGate.Free;
  FCS.Free;
  inherited Destroy;
end;

procedure TRdpListenerThread.SyncLog;
begin
  if Assigned(FOnLog) then
    FOnLog(FSyncMsg);
end;

procedure TRdpListenerThread.DoLog(const AMsg: string);
begin
  FSyncMsg := AMsg;
  Synchronize(@SyncLog);
end;

procedure TRdpListenerThread.HandleConnect(Sender: TObject; AData: TSocketStream);
var
  RemoteIP: string;
  Conn: TRdpConnectionThread;
begin
  try
    RemoteIP := NetAddrToStr(TInetSockAddr(AData.RemoteAddress).sin_addr);
  except
    RemoteIP := '?.?.?.?';
  end;

  if not FGate.TryAcquire then
  begin
    try
      WriteEmptyPacket(AData, PT_BUSY);
    except
      // лучшее старание - если отправить не удалось, просто закрываем соединение
    end;
    DoLog(Format('Отклонено (уже есть активное подключение): %s', [RemoteIP]));
    AData.Free;
    Exit;
  end;

  Conn := TRdpConnectionThread.Create(AData, FGate, FPassword, RemoteIP, @DoLog);
  Conn.OnTerminate := @HandleConnTerminate;

  FCS.Enter;
  try
    FActiveConn := Conn;
  finally
    FCS.Leave;
  end;

  Conn.Start;
end;

procedure TRdpListenerThread.HandleConnTerminate(Sender: TObject);
begin
  // Вызывается через Synchronize из самого потока сессии (который сейчас блокирован
  // в ожидании возврата из этого Synchronize) - поэтому здесь нельзя вызывать
  // WaitFor/Free для Sender, это привело бы к взаимной блокировке. Поток сам
  // освободит себя (FreeOnTerminate=True) сразу после возврата из этого обработчика.
  FCS.Enter;
  try
    if FActiveConn = Sender then
      FActiveConn := nil;
  finally
    FCS.Leave;
  end;
end;

procedure TRdpListenerThread.Execute;
begin
  try
    FServer.OnConnect := @HandleConnect;
    FServer.StartAccepting;
  except
    on E: Exception do
      DoLog('Ошибка сервера: ' + E.Message);
  end;
end;

procedure TRdpListenerThread.RequestStop;
begin
  Terminate;
  if Assigned(FServer) then
    FServer.StopAccepting(True);
  FCS.Enter;
  try
    if Assigned(FActiveConn) then
      FActiveConn.ForceDisconnect;
  finally
    FCS.Leave;
  end;
end;

end.
