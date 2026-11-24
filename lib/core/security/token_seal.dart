// Locks a short secret (the chat sign-in) to this Windows user account, so
// a copied settings file is useless on another PC or account. Other
// platforms keep their existing storage.
export 'token_seal_stub.dart' if (dart.library.ffi) 'token_seal_ffi.dart';
