import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pointycastle/export.dart';

class VerifiedIdentity {
  final bool isValid;
  final String? referenceId;
  final String? name;
  final String? dateOfBirth;
  final String? gender;
  final Uint8List? photoBytes;
  final String? failureReason;

  VerifiedIdentity({
    required this.isValid,
    this.referenceId,
    this.name,
    this.dateOfBirth,
    this.gender,
    this.photoBytes,
    this.failureReason,
  });

  factory VerifiedIdentity.failed(String reason) =>
      VerifiedIdentity(isValid: false, failureReason: reason);
}

class QrDecoderService {
  static RSAPublicKey? _rootPublicKey;

  static Future<void> initializeCertificate({
    String certPath = 'assets/certs/root_authority.cer',
  }) async {
    try {
      Uint8List certBytes;
      try {
        final byteData = await rootBundle.load(certPath);
        certBytes = byteData.buffer.asUint8List();
      } catch (_) {
        certBytes = await File(certPath).readAsBytes();
      }

      if (certBytes.isNotEmpty && certBytes[0] == 0x2D) {
        final pemString = utf8.decode(certBytes);
        final base64Content = pemString
            .replaceAll(RegExp(r'-----BEGIN[^-]+-----'), '')
            .replaceAll(RegExp(r'-----END[^-]+-----'), '')
            .replaceAll(RegExp(r'\s+'), '');
        certBytes = base64Decode(base64Content);
      }

      _rootPublicKey = _extractRsaPublicKeyDirect(certBytes);
    } catch (e) {
      throw Exception('Failed to load root authority certificate: $e');
    }
  }

  static RSAPublicKey _extractRsaPublicKeyDirect(Uint8List bytes) {
    final rsaOid = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01];

    int oidIndex = -1;
    for (int i = 0; i <= bytes.length - rsaOid.length; i++) {
      bool match = true;
      for (int j = 0; j < rsaOid.length; j++) {
        if (bytes[i + j] != rsaOid[j]) {
          match = false;
          break;
        }
      }
      if (match) {
        oidIndex = i;
        break;
      }
    }

    if (oidIndex == -1) {
      throw const FormatException('RSA encryption OID not found in certificate.');
    }

    int bitStringIndex = -1;
    for (int i = oidIndex + rsaOid.length; i < bytes.length - 4; i++) {
      if (bytes[i] == 0x03) {
        bitStringIndex = i;
        break;
      }
    }

    if (bitStringIndex == -1) {
      throw const FormatException('SubjectPublicKey BIT STRING tag not found.');
    }

    int offset = bitStringIndex + 1;
    _readAsn1Length(bytes, offset);
    offset = _lastOffset + 1;

    if (bytes[offset] != 0x30) {
      throw const FormatException('Expected RSA public key SEQUENCE (0x30).');
    }
    offset += 1;
    _readAsn1Length(bytes, offset);
    offset = _lastOffset;

    // Modulus
    offset += 1;
    final modulusLen = _readAsn1Length(bytes, offset);
    offset = _lastOffset;
    final modulusBytes = bytes.sublist(offset, offset + modulusLen);
    offset += modulusLen;

    // Exponent
    offset += 1;
    final exponentLen = _readAsn1Length(bytes, offset);
    offset = _lastOffset;
    final exponentBytes = bytes.sublist(offset, offset + exponentLen);

    return RSAPublicKey(_decodeBigInt(modulusBytes), _decodeBigInt(exponentBytes));
  }

  static int _lastOffset = 0;

  static int _readAsn1Length(Uint8List bytes, int offset) {
    int firstByte = bytes[offset];
    if ((firstByte & 0x80) == 0) {
      _lastOffset = offset + 1;
      return firstByte;
    }
    int numOctets = firstByte & 0x7F;
    int len = 0;
    for (int i = 0; i < numOctets; i++) {
      len = (len << 8) | bytes[offset + 1 + i];
    }
    _lastOffset = offset + 1 + numOctets;
    return len;
  }

  static BigInt _decodeBigInt(Uint8List bytes) {
    BigInt result = BigInt.zero;
    for (int b in bytes) {
      result = (result << 8) | BigInt.from(b);
    }
    return result;
  }

  static Future<VerifiedIdentity> decodeAndVerify(Uint8List rawBytes) async {
    if (_rootPublicKey == null) {
      await initializeCertificate();
    }

    try {
      Uint8List payloadBytes = rawBytes;

      if (rawBytes.length > 2 && rawBytes[0] == 0x1F && rawBytes[1] == 0x8B) {
        payloadBytes = Uint8List.fromList(gzip.decode(rawBytes));
      } else if (rawBytes.length > 2 && rawBytes[0] == 0x78) {
        try {
          payloadBytes = Uint8List.fromList(zlib.decode(rawBytes));
        } catch (_) {}
      }

      if (payloadBytes.isEmpty || payloadBytes[0] != 0x30) {
        return VerifiedIdentity.failed('Invalid envelope format: Expected ASN.1 Sequence.');
      }

      int offset = 1;
      _readAsn1Length(payloadBytes, offset);
      offset = _lastOffset;

      // 1. Data element
      int dataStart = offset;
      offset += 1;
      int dataLen = _readAsn1Length(payloadBytes, offset);
      int headerLen = _lastOffset - dataStart;
      int totalDataLen = headerLen + dataLen;
      final signedData = payloadBytes.sublist(dataStart, dataStart + totalDataLen);
      offset = dataStart + totalDataLen;

      // 2. Algorithm ID sequence
      if (offset < payloadBytes.length && payloadBytes[offset] == 0x30) {
        int algoStart = offset;
        offset += 1;
        int algoLen = _readAsn1Length(payloadBytes, offset);
        offset = _lastOffset + algoLen;
      }

      // 3. Signature
      if (offset >= payloadBytes.length) {
        return VerifiedIdentity.failed('Malformed envelope: Missing signature block.');
      }

      int sigTag = payloadBytes[offset];
      offset += 1;
      int sigLen = _readAsn1Length(payloadBytes, offset);
      offset = _lastOffset;

      if (sigTag == 0x03) {
        offset += 1;
        sigLen -= 1;
      }

      final signatureBytes = payloadBytes.sublist(offset, offset + sigLen);

      final signer = Signer('SHA-256/RSA')
        ..init(false, PublicKeyParameter<RSAPublicKey>(_rootPublicKey!));

      final isValidSig = signer.verifySignature(signedData, RSASignature(signatureBytes));
      if (!isValidSig) {
        return VerifiedIdentity.failed('Signature mismatch: QR data was not signed by root authority.');
      }

      return _parseIdentityPayload(signedData);
    } catch (e) {
      return VerifiedIdentity.failed('Verification error: $e');
    }
  }

  static VerifiedIdentity _parseIdentityPayload(Uint8List dataBytes) {
    String? id, name, dob, gender;
    Uint8List? photo;

    for (int i = 0; i < dataBytes.length - 4; i++) {
      if (photo == null &&
          dataBytes[i] == 0xFF &&
          dataBytes[i + 1] == 0xD8 &&
          dataBytes[i + 2] == 0xFF) {
        photo = dataBytes.sublist(i);
        break;
      }

      if (dataBytes[i] == 0x13 || dataBytes[i] == 0x0C || dataBytes[i] == 0x16) {
        int strLen = dataBytes[i + 1];
        if (strLen > 0 && strLen < 128 && (i + 2 + strLen) <= dataBytes.length) {
          try {
            final str = utf8.decode(dataBytes.sublist(i + 2, i + 2 + strLen));
            if (id == null && RegExp(r'^[A-Z0-9-]{6,16}$').hasMatch(str)) {
              id = str;
            } else if (name == null && RegExp(r'^[A-Za-z\s]{3,40}$').hasMatch(str)) {
              name = str;
            } else if (dob == null && RegExp(r'\d{2}[-/]\d{2}[-/]\d{4}').hasMatch(str)) {
              dob = str;
            } else if (gender == null && (str == 'M' || str == 'F' || str == 'T')) {
              gender = str;
            }
          } catch (_) {}
        }
      }
    }

    return VerifiedIdentity(
      isValid: true,
      referenceId: id ?? 'CONFIRMED',
      name: name ?? 'Verified Holder',
      dateOfBirth: dob,
      gender: gender,
      photoBytes: photo,
    );
  }
}