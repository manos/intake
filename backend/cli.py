"""Local-only administration: python -m backend.cli --help."""

import argparse
import getpass
import os

from backend.db import backup, create_user, initialize


def main():
    parser = argparse.ArgumentParser(description="Intake local administration")
    commands = parser.add_subparsers(dest="command", required=True)
    add = commands.add_parser(
        "create-user", help="Create an account; password is prompted securely"
    )
    add.add_argument("username")
    save = commands.add_parser(
        "backup", help="Create a consistent SQLite backup (new file only)"
    )
    save.add_argument("destination")
    args = parser.parse_args()
    path = initialize(os.environ.get("CONFIG_DIR", "/config"))
    try:
        if args.command == "create-user":
            password = getpass.getpass("Password (12+ characters): ")
            if password != getpass.getpass("Confirm password: "):
                parser.error("Passwords differ")
            create_user(path, args.username, password)
            print("Account created.")
        else:
            backup(path, args.destination)
            print(
                "Consistent backup created. Protect this file: it contains journal data and password hashes."
            )
    except (ValueError, OSError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
