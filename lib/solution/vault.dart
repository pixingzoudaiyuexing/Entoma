import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class SessionVault {
  Future<String?> read();
  Future<void> write(String? value);
  Future<String?> readJournal();
  Future<void> writeJournal(String value);
}

// flutter_secure_storage_darwin 0.2.0 reads this legacy wire spelling.
// Its Dart option uses a different spelling, so explicitly send both.
class EntomaMacVaultOptions extends MacOsOptions {
  const EntomaMacVaultOptions() : super(usesDataProtectionKeychain: false);
  @override
  Map<String, String> toMap() =>
      {...super.toMap(), 'useDataProtectionKeyChain': 'false'};
}

class NativeSessionVault implements SessionVault {
  final FlutterSecureStorage storage;
  final String key;
  final Duration readTimeout;
  final Map<String, Future<String?>> _nativeReads = {};
  NativeSessionVault(
    String origin, {
    FlutterSecureStorage? storage,
    this.readTimeout = const Duration(seconds: 10),
  })  : storage = storage ??
            const FlutterSecureStorage(
              aOptions: AndroidOptions(
                resetOnError: false,
                migrateOnAlgorithmChange: false,
                keyCipherAlgorithm:
                    KeyCipherAlgorithm.RSA_ECB_OAEPwithSHA_256andMGF1Padding,
                storageCipherAlgorithm:
                    StorageCipherAlgorithm.AES_GCM_NoPadding,
              ),
              mOptions: EntomaMacVaultOptions(),
            ),
        key = 'entoma.session.v1.$origin';
  @override
  Future<String?> read() => _read(key);
  Future<String?> _read(String itemKey) {
    // A Dart timeout does not cancel SecItemCopyMatching. Reuse that native
    // operation until it settles instead of adding more calls to its serial queue.
    final pending = _nativeReads.putIfAbsent(itemKey, () {
      final operation = storage.read(key: itemKey);
      void release() {
        if (identical(_nativeReads[itemKey], operation)) {
          _nativeReads.remove(itemKey);
        }
      }

      operation.then((_) => release(), onError: (Object _, StackTrace __) {
        release();
      });
      return operation;
    });
    return pending.timeout(readTimeout);
  }

  @override
  Future<void> write(String? value) => value == null
      ? storage.delete(key: key)
      : storage.write(key: key, value: value);
  @override
  Future<String?> readJournal() => _read('$key.pending');
  @override
  Future<void> writeJournal(String value) =>
      storage.write(key: '$key.pending', value: value);
}
