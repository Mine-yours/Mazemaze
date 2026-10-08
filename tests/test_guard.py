import socket

import pytest


def test_guard_blocks_network():
    s = socket.socket()
    try:
        with pytest.raises(RuntimeError):
            s.connect(("127.0.0.1", 11434))
    finally:
        s.close()
    with pytest.raises(RuntimeError):
        socket.create_connection(("127.0.0.1", 11434))
