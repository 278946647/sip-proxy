from __future__ import annotations

import smtplib
from email.message import EmailMessage

from .email_settings import SmtpConfig, get_smtp_config


def send_email(subject: str, body: str, *, cfg: SmtpConfig | None = None) -> None:
    smtp_cfg = cfg or get_smtp_config()
    if not smtp_cfg:
        return

    msg = EmailMessage()
    msg["From"] = smtp_cfg.mail_from
    msg["To"] = smtp_cfg.mail_to
    msg["Subject"] = subject
    msg.set_content(body)

    with smtplib.SMTP(host=smtp_cfg.host, port=smtp_cfg.port, timeout=15) as smtp:
        if smtp_cfg.starttls:
            smtp.starttls()
        if smtp_cfg.username and smtp_cfg.password:
            smtp.login(smtp_cfg.username, smtp_cfg.password)
        smtp.send_message(msg)


def send_test_email(cfg: SmtpConfig) -> None:
    send_email(
        subject="[GFC] SMTP test",
        body="This is a test message from Global Forwarding Control Plane.",
        cfg=cfg,
    )

