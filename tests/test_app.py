from src.app import handler


def test_hello():
    event = {"rawPath": "/hello", "requestContext": {"http": {"method": "GET"}}}
    assert handler(event, None)["statusCode"] == 200


def test_not_found():
    event = {"rawPath": "/other", "requestContext": {"http": {"method": "GET"}}}
    assert handler(event, None)["statusCode"] == 404
