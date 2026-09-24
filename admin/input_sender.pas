unit input_sender;

{ TInputSender - преобразует события мыши/клавиатуры формы админа в команды
  протокола и отправляет их через TFrameReceiverThread.SendPacket.
  Координаты мыши принимаются уже в системе offscreen-битмапа (1:1 с виртуальным
  экраном клиента без учёта масштаба окна - пересчёт масштаба выполняет main_admin
  перед вызовом MouseMove), здесь остаётся только сложить со смещением виртуального
  экрана клиента (VirtualLeft/VirtualTop).
  Флаг ViewOnly ("только просмотр") полностью отключает отправку любых команд ввода. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, rdp_protocol, frame_receiver;

type
  TInputSender = class
  private
    FReceiver: TFrameReceiverThread;
    FViewOnly: Boolean;
  public
    constructor Create(AReceiver: TFrameReceiverThread);

    property ViewOnly: Boolean read FViewOnly write FViewOnly;

    procedure MouseMove(ABitmapX, ABitmapY: Integer);
    procedure MouseButton(ABtn: Byte; ADown: Boolean);
    procedure MouseWheel(ADelta: Integer);
    procedure KeyDown(AVK: Word);
    procedure KeyUp(AVK: Word);
    procedure KeyChar(const AUtf8: UTF8String);
    procedure SendCtrlAltDel;
  end;

implementation

constructor TInputSender.Create(AReceiver: TFrameReceiverThread);
begin
  inherited Create;
  FReceiver := AReceiver;
  FViewOnly := False;
end;

procedure TInputSender.MouseMove(ABitmapX, ABitmapY: Integer);
begin
  if FViewOnly or (FReceiver = nil) then Exit;
  FReceiver.SendPacket(PT_MOUSE_MOVE,
    EncodeMouseMove(FReceiver.VirtualLeft + ABitmapX, FReceiver.VirtualTop + ABitmapY));
end;

procedure TInputSender.MouseButton(ABtn: Byte; ADown: Boolean);
begin
  if FViewOnly or (FReceiver = nil) then Exit;
  FReceiver.SendPacket(PT_MOUSE_BTN, EncodeMouseBtn(ABtn, ADown));
end;

procedure TInputSender.MouseWheel(ADelta: Integer);
begin
  if FViewOnly or (FReceiver = nil) then Exit;
  FReceiver.SendPacket(PT_MOUSE_WHEEL, EncodeMouseWheel(Int16(ADelta)));
end;

procedure TInputSender.KeyDown(AVK: Word);
begin
  if FViewOnly or (FReceiver = nil) then Exit;
  FReceiver.SendPacket(PT_KEY_DOWN, EncodeKey(AVK));
end;

procedure TInputSender.KeyUp(AVK: Word);
begin
  if FViewOnly or (FReceiver = nil) then Exit;
  FReceiver.SendPacket(PT_KEY_UP, EncodeKey(AVK));
end;

procedure TInputSender.KeyChar(const AUtf8: UTF8String);
begin
  if FViewOnly or (FReceiver = nil) then Exit;
  FReceiver.SendPacket(PT_KEY_CHAR, EncodeKeyChar(AUtf8));
end;

procedure TInputSender.SendCtrlAltDel;
var
  Empty: TBytes;
begin
  if FViewOnly or (FReceiver = nil) then Exit;
  SetLength(Empty, 0);
  FReceiver.SendPacket(PT_SAS, Empty);
end;

end.
