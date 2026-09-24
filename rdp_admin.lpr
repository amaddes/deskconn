program rdp_admin;

{ Приложение администратора (запускается у управляющего): подключается к
  rdp_client, аутентифицируется и отображает удалённый экран. }

{$mode objfpc}{$H+}

uses
  {$IFDEF UNIX}
  cthreads,
  {$ENDIF}
  Interfaces, // подключает виджет-сет LCL, должен идти до модулей форм
  Forms, main_admin;

{$R *.res}

begin
  RequireDerivedFormResource := True;
  Application.Scaled := True;
  Application.Title := 'RDP Admin';
  Application.Initialize;
  Application.CreateForm(TfrmAdmin, frmAdmin);
  Application.Run;
end.
