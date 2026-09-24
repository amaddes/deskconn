unit rdp_crypto;

{ SHA-256 (собственная реализация - в стандартном пакете hash FPC 3.2.2 её нет),
  генерация соли рукопожатия и генерация пароля клиента вида "123456AB". }

{$mode objfpc}{$H+}
// SHA-256 - это модулярная арифметика по модулю 2^32 по определению алгоритма:
// переполнение UInt32 при сложении - не ошибка, а обязательная часть вычислений.
// Если в проекте включены проверки переполнения/диапазона (OverflowChecks/RangeChecks -
// как в rdp_client.lpi/rdp_admin.lpi), без {$Q-}{$R-} компилятор кидает EIntOverflow
// на каждом "естественном" переносе - и хэширование пароля падает без единого ответа
// по сети (см. диагностику 2026-09-22).
{$Q-}{$R-}

interface

uses
  SysUtils, Classes;

type
  TSHA256Digest = array[0..31] of Byte;

// Считает SHA-256 от содержимого буфера.
function SHA256Buf(const AData; ALen: PtrUInt): TSHA256Digest;
// Считает SHA-256 от строки байт (AnsiString/RawByteString трактуется как байты).
function SHA256Bytes(const AData: TBytes): TSHA256Digest;
// Вспомогательное: SHA256(пароль + соль), как того требует рукопожатие протокола.
function SHA256PasswordSalt(const APassword: RawByteString; const ASalt: TBytes): TSHA256Digest;

function DigestToBytes(const ADigest: TSHA256Digest): TBytes;
function DigestsEqual(const A, B: TSHA256Digest): Boolean;
function BytesToDigest(const AData: TBytes): TSHA256Digest;

// Генерирует криптографически некритичную, но непредсказуемую соль заданной длины.
function GenerateRandomBytes(ACount: Integer): TBytes;

// Генерирует пароль вида 6 цифр + 2 буквы, например "482913KQ".
function GenerateClientPassword: string;

implementation

const
  SHA256_K: array[0..63] of UInt32 = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2
  );

function ROR32(AValue: UInt32; ABits: Byte): UInt32; inline;
begin
  Result := (AValue shr ABits) or (AValue shl (32 - ABits));
end;

function SHA256Buf(const AData; ALen: PtrUInt): TSHA256Digest;
var
  H: array[0..7] of UInt32;
  W: array[0..63] of UInt32;
  A, B, C, D, E, F, G, Hh, T1, T2: UInt32;
  Msg: TBytes;
  MsgLen, PadLen, TotalLen: PtrUInt;
  BitLen: UInt64;
  i, j, BlockCount, Offs: PtrUInt;
  Src: PByte;
begin
  H[0] := $6a09e667; H[1] := $bb67ae85; H[2] := $3c6ef372; H[3] := $a54ff53a;
  H[4] := $510e527f; H[5] := $9b05688c; H[6] := $1f83d9ab; H[7] := $5be0cd19;

  // Дополнение сообщения: 0x80, нули, длина в битах (big-endian), кратно 64 байтам.
  MsgLen := ALen;
  BitLen := UInt64(MsgLen) * 8;
  PadLen := 1 + 8;
  TotalLen := MsgLen + PadLen;
  if (TotalLen mod 64) <> 0 then
    TotalLen := TotalLen + (64 - (TotalLen mod 64));

  SetLength(Msg, TotalLen);
  FillChar(Msg[0], TotalLen, 0);
  if MsgLen > 0 then
  begin
    Src := PByte(@AData);
    Move(Src^, Msg[0], MsgLen);
  end;
  Msg[MsgLen] := $80;
  for i := 0 to 7 do
    Msg[TotalLen - 1 - i] := Byte((BitLen shr (i * 8)) and $FF);

  BlockCount := TotalLen div 64;
  for i := 0 to BlockCount - 1 do
  begin
    Offs := i * 64;
    for j := 0 to 15 do
      W[j] := (UInt32(Msg[Offs + j*4]) shl 24) or (UInt32(Msg[Offs + j*4 + 1]) shl 16) or
              (UInt32(Msg[Offs + j*4 + 2]) shl 8) or UInt32(Msg[Offs + j*4 + 3]);
    for j := 16 to 63 do
      W[j] := W[j-16] + (ROR32(W[j-15], 7) xor ROR32(W[j-15], 18) xor (W[j-15] shr 3))
                       + W[j-7]
                       + (ROR32(W[j-2], 17) xor ROR32(W[j-2], 19) xor (W[j-2] shr 10));

    A := H[0]; B := H[1]; C := H[2]; D := H[3];
    E := H[4]; F := H[5]; G := H[6]; Hh := H[7];

    for j := 0 to 63 do
    begin
      T1 := Hh + (ROR32(E,6) xor ROR32(E,11) xor ROR32(E,25)) + ((E and F) xor ((not E) and G)) + SHA256_K[j] + W[j];
      T2 := (ROR32(A,2) xor ROR32(A,13) xor ROR32(A,22)) + ((A and B) xor (A and C) xor (B and C));
      Hh := G; G := F; F := E; E := D + T1;
      D := C; C := B; B := A; A := T1 + T2;
    end;

    H[0] := H[0] + A; H[1] := H[1] + B; H[2] := H[2] + C; H[3] := H[3] + D;
    H[4] := H[4] + E; H[5] := H[5] + F; H[6] := H[6] + G; H[7] := H[7] + Hh;
  end;

  for i := 0 to 7 do
  begin
    Result[i*4]   := Byte((H[i] shr 24) and $FF);
    Result[i*4+1] := Byte((H[i] shr 16) and $FF);
    Result[i*4+2] := Byte((H[i] shr 8) and $FF);
    Result[i*4+3] := Byte(H[i] and $FF);
  end;
end;

function SHA256Bytes(const AData: TBytes): TSHA256Digest;
begin
  if Length(AData) = 0 then
    Result := SHA256Buf(Pointer(nil)^, 0)
  else
    Result := SHA256Buf(AData[0], Length(AData));
end;

function SHA256PasswordSalt(const APassword: RawByteString; const ASalt: TBytes): TSHA256Digest;
var
  Combined: TBytes;
  PwLen, SaltLen: Integer;
begin
  PwLen := Length(APassword);
  SaltLen := Length(ASalt);
  SetLength(Combined, PwLen + SaltLen);
  if PwLen > 0 then
    Move(APassword[1], Combined[0], PwLen);
  if SaltLen > 0 then
    Move(ASalt[0], Combined[PwLen], SaltLen);
  Result := SHA256Bytes(Combined);
end;

function DigestToBytes(const ADigest: TSHA256Digest): TBytes;
begin
  SetLength(Result, 32);
  Move(ADigest[0], Result[0], 32);
end;

function BytesToDigest(const AData: TBytes): TSHA256Digest;
begin
  FillChar(Result[0], 32, 0);
  if Length(AData) >= 32 then
    Move(AData[0], Result[0], 32);
end;

function DigestsEqual(const A, B: TSHA256Digest): Boolean;
var
  i: Integer;
  Diff: Byte;
begin
  // Сравнение за постоянное время, чтобы не давать канал по времени для подбора хэша.
  Diff := 0;
  for i := 0 to 31 do
    Diff := Diff or (A[i] xor B[i]);
  Result := Diff = 0;
end;

function GenerateRandomBytes(ACount: Integer): TBytes;
var
  i: Integer;
begin
  SetLength(Result, ACount);
  for i := 0 to ACount - 1 do
    Result[i] := Byte(Random(256));
end;

function GenerateClientPassword: string;
const
  Letters = 'ABCDEFGHJKLMNPQRSTUVWXYZ'; // без похожих на цифры символов (O, I исключены)
var
  Digits: string;
  L1, L2: Char;
begin
  Digits := Format('%.6d', [Random(1000000)]);
  L1 := Letters[Random(Length(Letters)) + 1];
  L2 := Letters[Random(Length(Letters)) + 1];
  Result := Digits + L1 + L2;
end;

initialization
  Randomize;

end.
