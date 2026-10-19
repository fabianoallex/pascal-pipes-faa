unit Pipes.AddressTests;

{ Testes do parsing de endereco TCP (PipeParseHostPort) e da validacao de
  coerencia entre Address e Transport (PipeValidateAddress), ambos em
  Pipes.Transport. Mestre DUnitX; o espelho FPCUnit em tests/Unit/fpc e' gerado
  por tools/gen_fpc_mirror.py. }

interface

uses
  DUnitX.TestFramework,
  Pipes.DUnitXCompat,
  SysUtils,
  Pipes.Types,
  Pipes.Transport;

type
  [TestFixture]
  TPipeAddressTests = class
  private
    FAddress: string;
    FTransport: TPipeTransport;
    procedure DoParse;
    procedure DoValidate;
    /// Afirma que AAddress e' parseado em AHost/APort.
    procedure CheckHostPort(const AAddress, AHost: string; APort: Word);
    /// Afirma que AAddress e' recusado por PipeParseHostPort.
    procedure CheckParseFails(const AAddress: string);
    /// Afirma que o par (AAddress, ATransport) e' recusado.
    procedure CheckInvalid(const AAddress: string; ATransport: TPipeTransport);
    /// Afirma que o par (AAddress, ATransport) e' aceito.
    procedure CheckValid(const AAddress: string; ATransport: TPipeTransport);
  public
    [Test] procedure ParseHostPort_IPv4;
    [Test] procedure ParseHostPort_NomeDeHost;
    [Test] procedure ParseHostPort_PortasLimite;
    [Test] procedure ParseHostPort_AsteriscoViraTodasAsInterfaces;
    [Test] procedure ParseHostPort_IPv6EntreColchetes;
    [Test] procedure ParseHostPort_SemPorta_Levanta;
    [Test] procedure ParseHostPort_PortaNaoNumerica_Levanta;
    [Test] procedure ParseHostPort_PortaForaDaFaixa_Levanta;
    [Test] procedure ParseHostPort_SemHost_Levanta;
    [Test] procedure ParseHostPort_Vazio_Levanta;
    [Test] procedure ParseHostPort_IPv6SemColchete_Levanta;
    [Test] procedure ParseHostPort_IPv6SemPorta_Levanta;
    [Test] procedure Validate_LocalAceitaNomeSimplesECaminhoNativo;
    [Test] procedure Validate_TcpAceitaHostPorta;
    [Test] procedure Validate_TcpRecusaCaminhoDePipeWindows;
    [Test] procedure Validate_TcpRecusaCaminhoDeSocketPosix;
    [Test] procedure Validate_TcpRecusaEnderecoMalformado;
    [Test] procedure Validate_AddressVazio_Levanta;
  end;

implementation

{ TPipeAddressTests }

procedure TPipeAddressTests.DoParse;
var
  LHost: string;
  LPort: Word;
begin
  PipeParseHostPort(FAddress, LHost, LPort);
end;

procedure TPipeAddressTests.DoValidate;
begin
  PipeValidateAddress(FAddress, FTransport);
end;

procedure TPipeAddressTests.CheckHostPort(const AAddress, AHost: string;
  APort: Word);
var
  LHost: string;
  LPort: Word;
begin
  PipeParseHostPort(AAddress, LHost, LPort);
  TAssert.AssertEquals('host de ' + AAddress, AHost, LHost);
  TAssert.AssertEquals('porta de ' + AAddress, Integer(APort), Integer(LPort));
end;

procedure TPipeAddressTests.CheckParseFails(const AAddress: string);
begin
  FAddress := AAddress;
  TAssert.AssertException('deveria recusar "' + AAddress + '"', EPipeError, DoParse);
end;

procedure TPipeAddressTests.CheckInvalid(const AAddress: string;
  ATransport: TPipeTransport);
begin
  FAddress := AAddress;
  FTransport := ATransport;
  TAssert.AssertException('deveria recusar "' + AAddress + '"', EPipeError, DoValidate);
end;

procedure TPipeAddressTests.CheckValid(const AAddress: string;
  ATransport: TPipeTransport);
begin
  PipeValidateAddress(AAddress, ATransport); // nao deve levantar
  TAssert.AssertTrue('"' + AAddress + '" deveria ser aceito', True);
end;

procedure TPipeAddressTests.ParseHostPort_IPv4;
begin
  CheckHostPort('127.0.0.1:5000', '127.0.0.1', 5000);
  CheckHostPort('0.0.0.0:8080', '0.0.0.0', 8080);
end;

procedure TPipeAddressTests.ParseHostPort_NomeDeHost;
begin
  CheckHostPort('localhost:5000', 'localhost', 5000);
  CheckHostPort('servidor.local:15672', 'servidor.local', 15672);
end;

procedure TPipeAddressTests.ParseHostPort_PortasLimite;
begin
  CheckHostPort('localhost:1', 'localhost', 1);
  CheckHostPort('localhost:65535', 'localhost', 65535);
end;

procedure TPipeAddressTests.ParseHostPort_AsteriscoViraTodasAsInterfaces;
begin
  CheckHostPort('*:5000', '0.0.0.0', 5000);
end;

procedure TPipeAddressTests.ParseHostPort_IPv6EntreColchetes;
begin
  // O separador de porta e' o ':' depois do ']' — o host tem ':' de sobra.
  CheckHostPort('[::1]:5000', '::1', 5000);
  CheckHostPort('[fe80::1]:80', 'fe80::1', 80);
end;

procedure TPipeAddressTests.ParseHostPort_SemPorta_Levanta;
begin
  CheckParseFails('localhost');
  CheckParseFails('127.0.0.1');
end;

procedure TPipeAddressTests.ParseHostPort_PortaNaoNumerica_Levanta;
begin
  CheckParseFails('localhost:abc');
  CheckParseFails('localhost:');
  CheckParseFails('localhost:50a0');
end;

procedure TPipeAddressTests.ParseHostPort_PortaForaDaFaixa_Levanta;
begin
  CheckParseFails('localhost:0');      // 0 nao e' porta utilizavel
  CheckParseFails('localhost:65536');
  CheckParseFails('localhost:-1');
end;

procedure TPipeAddressTests.ParseHostPort_SemHost_Levanta;
begin
  CheckParseFails(':5000');
end;

procedure TPipeAddressTests.ParseHostPort_Vazio_Levanta;
begin
  CheckParseFails('');
end;

procedure TPipeAddressTests.ParseHostPort_IPv6SemColchete_Levanta;
begin
  CheckParseFails('[::1:5000');
end;

procedure TPipeAddressTests.ParseHostPort_IPv6SemPorta_Levanta;
begin
  CheckParseFails('[::1]');
  CheckParseFails('[::1]5000'); // falta o ':'
end;

procedure TPipeAddressTests.Validate_LocalAceitaNomeSimplesECaminhoNativo;
begin
  CheckValid('MeuPipe', ptLocal);
  CheckValid('\\.\pipe\MeuPipe', ptLocal);
  CheckValid('/tmp/meu.sock', ptLocal);
  // Um endereco host:porta nao e' proibido em ptLocal: seria um nome de pipe
  // esquisito, mas valido — a validacao nao tenta adivinhar a intencao.
  CheckValid('127.0.0.1:5000', ptLocal);
end;

procedure TPipeAddressTests.Validate_TcpAceitaHostPorta;
begin
  CheckValid('0.0.0.0:5000', ptTcp);
  CheckValid('[::1]:5000', ptTcp);
  CheckValid('*:5000', ptTcp);
end;

procedure TPipeAddressTests.Validate_TcpRecusaCaminhoDePipeWindows;
begin
  CheckInvalid('\\.\pipe\MeuPipe', ptTcp);
end;

procedure TPipeAddressTests.Validate_TcpRecusaCaminhoDeSocketPosix;
begin
  CheckInvalid('/tmp/meu.sock', ptTcp);
end;

procedure TPipeAddressTests.Validate_TcpRecusaEnderecoMalformado;
begin
  CheckInvalid('MeuPipe', ptTcp);        // sem porta
  CheckInvalid('localhost:abc', ptTcp);  // porta nao numerica
end;

procedure TPipeAddressTests.Validate_AddressVazio_Levanta;
begin
  CheckInvalid('', ptLocal);
  CheckInvalid('', ptTcp);
end;

initialization
  TDUnitX.RegisterTestFixture(TPipeAddressTests);

end.
