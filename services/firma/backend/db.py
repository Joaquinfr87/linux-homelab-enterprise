#!/usr/bin/env python3
"""Módulo de base de datos SQLite para gestión de usuarios,
credenciales criptográficas y bitácora de auditoría de firmas.
"""

import datetime
import sqlite3
from pathlib import Path

DATA_DIR = Path(__file__).resolve().parent / "data"
DB_PATH = DATA_DIR / "app.db"


def get_db():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH))
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    return conn


def init_db():
    """Crea las tablas necesarias si aún no existen."""
    conn = get_db()
    with conn:
        conn.execute("""
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                email TEXT UNIQUE NOT NULL COLLATE NOCASE,
                password_hash TEXT NOT NULL,
                full_name TEXT NOT NULL,
                organization TEXT DEFAULT 'Universidad Privada Domingo Savio',
                unit TEXT DEFAULT 'Seguridad Informatica',
                city TEXT DEFAULT 'La Paz',
                country TEXT DEFAULT 'BO',
                cert_pem TEXT NOT NULL,
                encrypted_key BLOB NOT NULL,
                p12_bytes BLOB,
                p12_password TEXT,
                serial_hex TEXT,
                fingerprint_sha256 TEXT,
                valid_from TEXT,
                valid_to TEXT,
                created_at TEXT NOT NULL
            )
        """)
        conn.execute("""
            CREATE TABLE IF NOT EXISTS audit_logs (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                user_id INTEGER,
                action TEXT NOT NULL,
                details TEXT,
                filename TEXT,
                file_hash TEXT,
                created_at TEXT NOT NULL,
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
            )
        """)
    conn.close()


def create_user(
    email: str,
    password_hash: str,
    full_name: str,
    organization: str,
    unit: str,
    city: str,
    country: str,
    cred: dict,
    p12_password: str = "",
) -> int:
    """Inserta un nuevo usuario con su credencial criptográfica."""
    conn = get_db()
    now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()
    with conn:
        cur = conn.execute(
            """
            INSERT INTO users (
                email, password_hash, full_name, organization, unit, city, country,
                cert_pem, encrypted_key, p12_bytes, p12_password,
                serial_hex, fingerprint_sha256, valid_from, valid_to, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                email.strip().lower(),
                password_hash,
                full_name.strip(),
                organization.strip(),
                unit.strip(),
                city.strip(),
                country.strip(),
                cred["cert_pem"],
                cred["encrypted_key"],
                cred["p12_bytes"],
                p12_password,
                cred["serial_hex"],
                cred["fingerprint_sha256"],
                cred["valid_from"],
                cred["valid_to"],
                now_iso,
            ),
        )
        user_id = cur.lastrowid
    conn.close()
    return user_id


def get_user_by_email(email: str):
    conn = get_db()
    cur = conn.execute("SELECT * FROM users WHERE email = ? COLLATE NOCASE", (email.strip().lower(),))
    row = cur.fetchone()
    conn.close()
    return dict(row) if row else None


def get_user_by_id(user_id: int):
    conn = get_db()
    cur = conn.execute("SELECT * FROM users WHERE id = ?", (user_id,))
    row = cur.fetchone()
    conn.close()
    return dict(row) if row else None


def log_audit(user_id: int, action: str, details: str = "", filename: str = "", file_hash: str = ""):
    conn = get_db()
    now_iso = datetime.datetime.now(datetime.timezone.utc).isoformat()
    with conn:
        conn.execute(
            """
            INSERT INTO audit_logs (user_id, action, details, filename, file_hash, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """,
            (user_id, action, details, filename, file_hash, now_iso),
        )
    conn.close()


def get_user_audit_logs(user_id: int, limit: int = 15):
    conn = get_db()
    cur = conn.execute(
        """
        SELECT id, action, details, filename, file_hash, created_at
        FROM audit_logs
        WHERE user_id = ?
        ORDER BY id DESC
        LIMIT ?
        """,
        (user_id, limit),
    )
    rows = [dict(r) for r in cur.fetchall()]
    conn.close()
    return rows
