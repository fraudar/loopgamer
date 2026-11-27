import 'dart:io';

/// Remove um diretório temporário tolerando locks transitórios do Windows.
///
/// Handles abertos por isolate/rede/lazy writer mantêm o diretório preso por
/// alguns milissegundos após o teste; sem retry o tearDown falha com
/// `PathAccessException` e derruba testes que passaram.
void deleteTempDirQuietly(Directory dir) {
  if (!dir.existsSync()) return;
  for (var attempt = 0; attempt < 20; attempt++) {
    try {
      dir.deleteSync(recursive: true);
      return;
    } on FileSystemException {
      sleep(const Duration(milliseconds: 50));
    }
  }
  try {
    dir.deleteSync(recursive: true);
  } on FileSystemException {
    // Diretório residual no TEMP é aceitável; não mascara falha real.
  }
}
