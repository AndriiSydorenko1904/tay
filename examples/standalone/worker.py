from tay import Tay


tay = Tay(mode="worker", client_id="standalone-example")


@tay.task(name="example.echo.v1")
def echo(message: str) -> dict[str, str]:
    return {"message": message}
