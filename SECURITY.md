# Security

TV Ferry talks **plain FTP** because that is what File Manager+'s "Access from network" offers. On FTP the password and files travel unencrypted, so only use it on a home network you trust, and stop the service on the TV when you are done.

The password is stored in the macOS Keychain and is passed to `curl` on stdin, never on the command line.

To report a vulnerability, please open a GitHub security advisory on this repository rather than a public issue.
