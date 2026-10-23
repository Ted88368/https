#!/usr/bin/env python3
import os
import re
import shlex
import sys

def main():
    mode = os.environ.get("MODE", "letsencrypt").strip()
    server_name = os.environ.get("SERVER_NAME", "").strip()
    domains_env = os.environ.get("DOMAINS", "").strip()
    public_ip = os.environ.get("PUBLIC_IP", "").strip()
    sign_ip_env = os.environ.get("SIGN_IP", "auto").strip().lower()
    staging = os.environ.get("LETSENCRYPT_STAGING", "1").strip()
    cert_name_env = os.environ.get("CERT_NAME", "").strip()
    pref_profile = os.environ.get("PREFERRED_PROFILE", "").strip()
    webroot = os.environ.get("WEBROOT", "/var/www/certbot").strip()
    email = os.environ.get("ACME_EMAIL", "").strip()

    raw_tokens = (domains_env + " " + server_name).replace(",", " ").split()
    parsed_domains = []
    seen = set()
    ip_pattern = re.compile(r"^(\d{1,3}\.){3}\d{1,3}$|^[0-9a-fA-F:]+$")

    for token in raw_tokens:
        token = token.strip()
        if not token or token in ("_", "localhost", "127.0.0.1", "::1"):
            continue
        if ip_pattern.match(token):
            continue
        if "." in token and token not in seen:
            seen.add(token)
            parsed_domains.append(token)

    has_public_ip = bool(
        public_ip
        and public_ip not in ("127.0.0.1", "localhost", "::1")
        and ip_pattern.match(public_ip)
    )

    include_ip = False
    if has_public_ip:
        if sign_ip_env in ("0", "false", "no"):
            include_ip = False
        else:
            include_ip = True

    suffix = "staging" if staging == "1" else "prod"
    ip_slug = public_ip.replace(":", "-")

    if cert_name_env:
        cert_name = cert_name_env
    elif include_ip:
        cert_name = f"ip-{ip_slug}-{suffix}"
    elif parsed_domains:
        cert_name = f"domain-{parsed_domains[0]}-{suffix}"
    else:
        cert_name = f"cert-{suffix}"

    primary_name = parsed_domains[0] if parsed_domains else (public_ip if has_public_ip else "localhost")

    nginx_names = []
    if server_name and server_name != "_":
        for part in server_name.replace(",", " ").split():
            if part not in nginx_names:
                nginx_names.append(part)
    for d in parsed_domains:
        if d not in nginx_names:
            nginx_names.append(d)
    if has_public_ip and public_ip not in nginx_names:
        nginx_names.append(public_ip)
    if not nginx_names:
        nginx_names = ["_"]

    certbot_flags = [
        "certonly",
        "--webroot",
        "--webroot-path", webroot,
        "--cert-name", cert_name,
        "--agree-tos",
        "--non-interactive",
        "--expand",
        "--keep-until-expiring",
    ]

    for d in parsed_domains:
        certbot_flags.extend(["-d", d])

    if include_ip:
        certbot_flags.extend(["--ip-address", public_ip])
        certbot_flags.extend(["--preferred-profile", pref_profile or "shortlived"])
    elif pref_profile:
        certbot_flags.extend(["--preferred-profile", pref_profile])

    if staging == "1":
        certbot_flags.append("--staging")

    if email:
        certbot_flags.extend(["--email", email])
    else:
        certbot_flags.append("--register-unsafely-without-email")

    san_entries = []
    for d in parsed_domains:
        san_entries.append(f"DNS:{d}")
    if include_ip:
        san_entries.append(f"IP:{public_ip}")
    elif not parsed_domains and has_public_ip:
        san_entries.append(f"IP:{public_ip}")
    san_str = ",".join(san_entries) if san_entries else "DNS:localhost,IP:127.0.0.1"

    valid_count = len(parsed_domains) + (1 if include_ip else 0)

    print(f"CERT_NAME={shlex.quote(cert_name)}")
    print(f"LE_LIVE_DIR={shlex.quote(f'/etc/letsencrypt/live/{cert_name}')}")
    print(f"PRIMARY_NAME={shlex.quote(primary_name)}")
    print(f"BOOTSTRAP_SAN={shlex.quote(san_str)}")
    print(f"INCLUDE_IP={'1' if include_ip else '0'}")
    print(f"HAS_PUBLIC_IP={'1' if has_public_ip else '0'}")
    print(f"PARSED_DOMAINS={shlex.quote(' '.join(parsed_domains))}")
    print(f"FINAL_SERVER_NAMES={shlex.quote(' '.join(nginx_names))}")
    print(f"CERTBOT_ARGS_CMD={shlex.quote(' '.join(shlex.quote(x) for x in certbot_flags))}")
    print(f"VALID_IDENTIFIERS_COUNT={valid_count}")

if __name__ == "__main__":
    main()
