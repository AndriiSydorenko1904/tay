"""Exercise the live test listener with explicit CA and hostname verification."""

import asyncio
import http.client
import json
import pathlib
import socket
import ssl
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "clients/python"))
from tay import ServerError, TayHTTP


def main() -> None:
    port, ca, cert, key, untrusted_cert = sys.argv[1:]
    port = int(port)

    def context(client_cert: str | None = None, authority: str = ca) -> ssl.SSLContext:
        ctx = ssl.create_default_context(cafile=authority)
        assert ctx.verify_mode == ssl.CERT_REQUIRED and ctx.check_hostname
        if client_cert:
            ctx.load_cert_chain(client_cert, key)
        return ctx

    def request(ctx: ssl.SSLContext) -> tuple[int, dict]:
        connection = http.client.HTTPSConnection(
            "127.0.0.1", port, context=ctx, timeout=5
        )
        try:
            connection.request("GET", "/unknown")
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    status, body = request(context(cert))
    assert status == 404 and body["error"]["code"] == "not_found", (status, body)

    # A generic connection failure is insufficient: require a TLS alert from
    # the server, after the client has successfully verified its certificate.
    for identity in [None, untrusted_cert]:
        try:
            request(context(identity))
        except ssl.SSLError as error:
            assert not isinstance(error, ssl.SSLCertVerificationError), error
            assert error.reason in {
                "TLSV13_ALERT_CERTIFICATE_REQUIRED",
                "SSLV3_ALERT_HANDSHAKE_FAILURE",
                "TLSV1_ALERT_UNKNOWN_CA",
                "SSLV3_ALERT_BAD_CERTIFICATE",
            }, error
        else:
            raise AssertionError(f"server accepted untrusted client: {identity}")

    try:
        request(context(cert, authority=untrusted_cert))
    except ssl.SSLCertVerificationError:
        pass
    else:
        raise AssertionError("client accepted a server without its trusted CA")

    try:
        with (
            socket.create_connection(("127.0.0.1", port), timeout=5) as raw,
            context(cert).wrap_socket(raw, server_hostname="wrong.tay.invalid"),
        ):
            raise AssertionError("client accepted the wrong server hostname")
    except ssl.SSLCertVerificationError as error:
        assert error.verify_code == 62, error  # X509_V_ERR_HOSTNAME_MISMATCH

    async def sdk_request() -> None:
        async with TayHTTP(
            f"https://127.0.0.1:{port}",
            tls_ca_file=ca,
            tls_cert_file=cert,
            tls_key_file=key,
        ) as tay:
            try:
                await tay._request("GET", "/unknown")
            except ServerError as error:
                assert error.code == "not_found", error
            else:
                raise AssertionError("missing expected HTTP API error")

    asyncio.run(sdk_request())
    print(
        "mTLS: trusted client accepted; missing/untrusted clients, wrong CA and hostname rejected"
    )


if __name__ == "__main__":
    main()
