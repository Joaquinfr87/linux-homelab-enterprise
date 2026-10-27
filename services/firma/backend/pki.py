#!/usr/bin/env python3
"""Módulo PKI y Criptografía para la Suite de Firma Digital UPDS.
Gestiona:
1. Autoridad Certificadora Raíz institucional (CA UPDS).
2. Emisión de certificados X.509 v3 para usuarios registrados.
3. Generación de paquetes PKCS#12 (.p12).
4. Cifrado simétrico autenticado (AES/Fernet) para custodia segura de claves privadas en la BD.
"""

import datetime
import os
from pathlib import Path
from cryptography import x509
from cryptography.fernet import Fernet
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.hazmat.primitives.serialization.pkcs12 import (
    serialize_key_and_certificates,
    load_pkcs12,
)
from cryptography.x509.oid import NameOID, ExtendedKeyUsageOID

DATA_DIR = Path(__file__).resolve().parent / "data"
CA_DIR = DATA_DIR / "ca"
CA_KEY_PATH = CA_DIR / "upds_ca.key"
CA_CERT_PATH = CA_DIR / "upds_ca.crt"
MASTER_KEY_PATH = DATA_DIR / ".master_key"


def _get_master_fernet():
    """Obtiene o inicializa la clave maestra simétrica para cifrar las claves privadas en BD."""
    if not MASTER_KEY_PATH.exists():
        key = Fernet.generate_key()
        MASTER_KEY_PATH.parent.mkdir(parents=True, exist_ok=True)
        MASTER_KEY_PATH.write_bytes(key)
        try:
            os.chmod(MASTER_KEY_PATH, 0o600)
        except Exception:
            pass
        return Fernet(key)
    return Fernet(MASTER_KEY_PATH.read_bytes().strip())


def encrypt_private_key(key_pem: bytes) -> bytes:
    """Cifra la clave privada en formato PEM usando cifrado simétrico autenticado."""
    f = _get_master_fernet()
    return f.encrypt(key_pem)


def decrypt_private_key(encrypted_blob: bytes):
    """Descifra el blob y carga el objeto RSAPrivateKey en memoria RAM."""
    f = _get_master_fernet()
    pem_bytes = f.decrypt(encrypted_blob)
    return serialization.load_pem_private_key(pem_bytes, password=None)


def ensure_ca():
    """Inicializa la Autoridad Certificadora Raíz UPDS si no existe."""
    CA_DIR.mkdir(parents=True, exist_ok=True)
    if CA_KEY_PATH.exists() and CA_CERT_PATH.exists():
        ca_key = serialization.load_pem_private_key(CA_KEY_PATH.read_bytes(), password=None)
        ca_cert = x509.load_pem_x509_certificate(CA_CERT_PATH.read_bytes())
        return ca_key, ca_cert

    # Generar nueva CA Raíz de 4096 bits para la universidad
    ca_key = rsa.generate_private_key(public_exponent=65537, key_size=4096)
    
    try:
        now = datetime.datetime.now(datetime.timezone.utc)
    except AttributeError:
        now = datetime.datetime.utcnow()

    ca_name = x509.Name([
        x509.NameAttribute(NameOID.COUNTRY_NAME, "BO"),
        x509.NameAttribute(NameOID.STATE_OR_PROVINCE_NAME, "La Paz"),
        x509.NameAttribute(NameOID.LOCALITY_NAME, "La Paz"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, "Universidad Privada Domingo Savio"),
        x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, "Autoridad Certificadora Raiz UPDS"),
        x509.NameAttribute(NameOID.COMMON_NAME, "Autoridad Certificadora Raiz UPDS"),
    ])

    ca_cert = (
        x509.CertificateBuilder()
        .subject_name(ca_name)
        .issuer_name(ca_name)
        .public_key(ca_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now)
        .not_valid_after(now + datetime.timedelta(days=3650))  # 10 años
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=False,
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=True,
                crl_sign=True,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(
            x509.SubjectKeyIdentifier.from_public_key(ca_key.public_key()),
            critical=False,
        )
        .sign(ca_key, hashes.SHA256())
    )

    # Persistir CA
    CA_KEY_PATH.write_bytes(
        ca_key.private_bytes(
            encoding=serialization.Encoding.PEM,
            format=serialization.PrivateFormat.PKCS8,
            encryption_algorithm=serialization.NoEncryption(),
        )
    )
    try:
        os.chmod(CA_KEY_PATH, 0o600)
    except Exception:
        pass

    CA_CERT_PATH.write_bytes(ca_cert.public_bytes(serialization.Encoding.PEM))
    return ca_key, ca_cert


def get_ca():
    """Retorna la clave y el certificado de la CA."""
    return ensure_ca()


def get_ca_cert_pem() -> bytes:
    """Retorna los bytes PEM del certificado CA Raíz."""
    _, ca_cert = ensure_ca()
    return ca_cert.public_bytes(serialization.Encoding.PEM)


def format_fingerprint(cert):
    """Devuelve la huella digital SHA-256 en formato legible XX:XX:..."""
    try:
        raw_fp = cert.fingerprint(hashes.SHA256()).hex().upper()
        return ":".join(raw_fp[i:i+2] for i in range(0, len(raw_fp), 2))
    except Exception:
        return "N/D"


def issue_user_credential(
    full_name: str,
    email: str,
    organization: str = "Universidad Privada Domingo Savio",
    unit: str = "Seguridad Informatica",
    city: str = "La Paz",
    country: str = "BO",
    days: int = 365,
    p12_password: str = "UPDS2026",
):
    """Genera par de claves RSA (2048 bits) y emite un certificado X.509 v3
    firmado por la CA Raíz UPDS.
    Retorna diccionario con metadatos y los blobs criptográficos necesarios.
    """
    ca_key, ca_cert = ensure_ca()

    # 1. Par de claves RSA para el usuario
    user_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)

    try:
        now = datetime.datetime.now(datetime.timezone.utc)
    except AttributeError:
        now = datetime.datetime.utcnow()

    # 2. Nombre Distinguido (DN) del Sujeto
    name_attrs = [
        x509.NameAttribute(NameOID.COUNTRY_NAME, country or "BO"),
        x509.NameAttribute(NameOID.LOCALITY_NAME, city or "La Paz"),
        x509.NameAttribute(NameOID.ORGANIZATION_NAME, organization or "Universidad Privada Domingo Savio"),
        x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, unit or "Seguridad Informatica"),
        x509.NameAttribute(NameOID.COMMON_NAME, full_name.strip()),
    ]
    if email and email.strip():
        name_attrs.append(x509.NameAttribute(NameOID.EMAIL_ADDRESS, email.strip().lower()))

    subject = x509.Name(name_attrs)
    serial = x509.random_serial_number()
    valid_until = now + datetime.timedelta(days=days)

    # 3. Construcción del certificado X.509 v3 firmado por la CA
    user_cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(ca_cert.subject)
        .public_key(user_key.public_key())
        .serial_number(serial)
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(valid_until)
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(
            x509.KeyUsage(
                digital_signature=True,
                content_commitment=True,  # No repudio
                key_encipherment=False,
                data_encipherment=False,
                key_agreement=False,
                key_cert_sign=False,
                crl_sign=False,
                encipher_only=False,
                decipher_only=False,
            ),
            critical=True,
        )
        .add_extension(
            x509.ExtendedKeyUsage([
                ExtendedKeyUsageOID.EMAIL_PROTECTION,
                ExtendedKeyUsageOID.CLIENT_AUTH,
                ExtendedKeyUsageOID.CODE_SIGNING,
            ]),
            critical=False,
        )
        .add_extension(
            x509.SubjectKeyIdentifier.from_public_key(user_key.public_key()),
            critical=False,
        )
        .add_extension(
            x509.AuthorityKeyIdentifier.from_issuer_public_key(ca_key.public_key()),
            critical=False,
        )
        .sign(ca_key, hashes.SHA256())
    )

    # 4. Formatos de serialización
    user_key_pem = user_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )
    user_cert_pem = user_cert.public_bytes(serialization.Encoding.PEM)

    # Cifrar la clave privada para guardarla en la base de datos
    encrypted_key = encrypt_private_key(user_key_pem)

    # 5. Paquete PKCS#12 (.p12) que incluye la cadena de certificación
    p12_pwd = (p12_password or "UPDS2026").encode()
    try:
        p12_bytes = serialize_key_and_certificates(
            full_name.encode("utf-8", errors="ignore"),
            user_key,
            user_cert,
            cas=[ca_cert],
            encryption_algorithm=serialization.BestAvailableEncryption(p12_pwd),
        )
    except Exception:
        p12_bytes = None

    serial_hex = hex(serial)[2:].upper()
    fingerprint = format_fingerprint(user_cert)

    return {
        "user_key": user_key,
        "user_cert": user_cert,
        "key_pem": user_key_pem.decode("utf-8"),
        "cert_pem": user_cert_pem.decode("utf-8"),
        "encrypted_key": encrypted_key,
        "p12_bytes": p12_bytes,
        "serial_hex": serial_hex,
        "fingerprint_sha256": fingerprint,
        "valid_from": now.isoformat(),
        "valid_to": valid_until.isoformat(),
    }
