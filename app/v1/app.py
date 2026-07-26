import os
from typing import Any

import mysql.connector
from flask import Flask, redirect, render_template, request, url_for
from mysql.connector import Error

app = Flask(__name__)

APP_VERSION = os.getenv("APP_VERSION", "v1")
EXPECTED_SCHEMA_VERSION = int(os.getenv("EXPECTED_SCHEMA_VERSION", "1"))
STUDENT_ID = os.getenv("STUDENT_ID", "unknown-student")


def get_database_connection():
    """Create a new MySQL connection using environment variables."""
    return mysql.connector.connect(
        host=os.getenv("DB_HOST", "mysql"),
        port=int(os.getenv("DB_PORT", "3306")),
        user=os.getenv("DB_USER", "root"),
        password=os.getenv("DB_PASSWORD", ""),
        database=os.getenv("DB_NAME", "notesdb"),
        connection_timeout=5,
    )


def get_schema_version(connection: Any) -> int:
    """Read the current schema version directly from the database."""
    cursor = connection.cursor()
    try:
        cursor.execute("SELECT version FROM schema_version LIMIT 1")
        result = cursor.fetchone()

        if result is None:
            raise RuntimeError("schema_version table contains no version row")

        return int(result[0])
    finally:
        cursor.close()


@app.route("/", methods=["GET"])
def index():
    connection = None
    cursor = None

    try:
        connection = get_database_connection()
        schema_version = get_schema_version(connection)

        cursor = connection.cursor(dictionary=True)
        cursor.execute(
            """
            SELECT id, author, body, created_at
            FROM notes
            ORDER BY id DESC
            """
        )
        notes = cursor.fetchall()

        return render_template(
            "index.html",
            notes=notes,
            student_id=STUDENT_ID,
            app_version=APP_VERSION,
            schema_version=schema_version,
            error=None,
        )

    except Error as error:
        return render_template(
            "index.html",
            notes=[],
            student_id=STUDENT_ID,
            app_version=APP_VERSION,
            schema_version="unavailable",
            error=f"Database error: {error}",
        ), 500

    finally:
        if cursor is not None:
            cursor.close()

        if connection is not None and connection.is_connected():
            connection.close()


@app.route("/notes", methods=["POST"])
def create_note():
    body = request.form.get("body", "").strip()

    if not body:
        return redirect(url_for("index"))

    connection = None
    cursor = None

    try:
        connection = get_database_connection()
        schema_version = get_schema_version(connection)

        if schema_version != EXPECTED_SCHEMA_VERSION:
            return (
                f"Application {APP_VERSION} requires schema "
                f"{EXPECTED_SCHEMA_VERSION}, but database is schema "
                f"{schema_version}.",
                503,
            )

        cursor = connection.cursor()
        cursor.execute(
            """
            INSERT INTO notes (author, body)
            VALUES (%s, %s)
            """,
            (STUDENT_ID, body),
        )
        connection.commit()

        return redirect(url_for("index"))

    except Error as error:
        if connection is not None:
            connection.rollback()

        return f"Unable to save note: {error}", 500

    finally:
        if cursor is not None:
            cursor.close()

        if connection is not None and connection.is_connected():
            connection.close()


@app.route("/health", methods=["GET"])
def health():
    """Liveness endpoint: confirms that the web process is running."""
    return {
        "status": "healthy",
        "app_version": APP_VERSION,
        "student_id": STUDENT_ID,
    }, 200


@app.route("/ready", methods=["GET"])
def ready():
    """
    Readiness endpoint: confirms that MySQL is reachable and that the
    database schema matches the application version.
    """
    connection = None

    try:
        connection = get_database_connection()
        schema_version = get_schema_version(connection)

        if schema_version != EXPECTED_SCHEMA_VERSION:
            return {
                "status": "not-ready",
                "app_version": APP_VERSION,
                "expected_schema_version": EXPECTED_SCHEMA_VERSION,
                "actual_schema_version": schema_version,
            }, 503

        return {
            "status": "ready",
            "app_version": APP_VERSION,
            "schema_version": schema_version,
        }, 200

    except (Error, RuntimeError) as error:
        return {
            "status": "not-ready",
            "error": str(error),
        }, 503

    finally:
        if connection is not None and connection.is_connected():
            connection.close()


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
