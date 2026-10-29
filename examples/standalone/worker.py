import os

from tay import Tay, TayHTTPWorker

base_url = os.environ.get("TAY_HTTP_URL")
tay = (
    TayHTTPWorker(base_url, runtime_id="standalone-example")
    if base_url
    else Tay(mode="worker", client_id="standalone-example")
)


@tay.task(name="example.echo.v1")
def echo(message: str) -> dict[str, str]:
    return {"message": message}
