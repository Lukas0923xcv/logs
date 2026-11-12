#!/usr/bin/python
# -*- coding: utf-8 -*-

from __future__ import absolute_import, division, print_function

__metaclass__ = type

DOCUMENTATION = r"""
module: logs_notify
short_description: Send a plain-text mail over SMTP
description:
  - Small SMTP client so the collector needs no extra Ansible collection.
  - The password is passed as a module argument marked no_log. Take it from
    an environment variable or a secret store, never from a file in git.
options:
  host: {type: str, required: true}
  port: {type: int, default: 587}
  security: {type: str, default: starttls, choices: [starttls, tls, none]}
  username: {type: str}
  password: {type: str, no_log: true}
  sender: {type: str, required: true}
  recipients: {type: list, elements: str, required: true}
  subject: {type: str, required: true}
  body: {type: str, required: true}
"""

import smtplib
import ssl
from email.message import EmailMessage
from email.utils import formatdate, make_msgid

from ansible.module_utils.basic import AnsibleModule


def main():
    module = AnsibleModule(
        argument_spec=dict(
            host=dict(type="str", required=True),
            port=dict(type="int", default=587),
            security=dict(type="str", default="starttls", choices=["starttls", "tls", "none"]),
            username=dict(type="str"),
            password=dict(type="str", no_log=True),
            sender=dict(type="str", required=True),
            recipients=dict(type="list", elements="str", required=True),
            subject=dict(type="str", required=True),
            body=dict(type="str", required=True),
        ),
        supports_check_mode=True,
    )
    p = module.params
    if p["username"] and p["security"] == "none":
        module.fail_json(msg="refusing to send SMTP credentials without TLS (security: none)")
    if p["username"] and not p["password"]:
        module.fail_json(msg="an SMTP username is set but the password is empty (set LOGS_SMTP_PASSWORD)")
    if module.check_mode:
        module.exit_json(changed=False)

    msg = EmailMessage()
    msg["From"] = p["sender"]
    msg["To"] = ", ".join(p["recipients"])
    msg["Subject"] = p["subject"]
    msg["Date"] = formatdate(localtime=True)
    msg["Message-ID"] = make_msgid()
    msg.set_content(p["body"])
    try:
        context = ssl.create_default_context()
        if p["security"] == "tls":
            client = smtplib.SMTP_SSL(p["host"], p["port"], timeout=30, context=context)
        else:
            client = smtplib.SMTP(p["host"], p["port"], timeout=30)
        with client:
            if p["security"] == "starttls":
                client.starttls(context=context)
            if p["username"]:
                client.login(p["username"], p["password"])
            client.send_message(msg)
    except (smtplib.SMTPException, OSError) as exc:
        module.fail_json(msg="could not send mail: %s" % exc)
    module.exit_json(changed=True)


if __name__ == "__main__":
    main()
