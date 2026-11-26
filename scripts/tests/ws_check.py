#!/usr/bin/env python3
"""WebSocket 链路自检（纯标准库，不依赖任何第三方包）。

在主机上跑：
    python3 ws_check.py [host] [port] [帧数]

它做三件事：
  1. 校验握手：用 hashlib 独立算出 Sec-WebSocket-Accept，和服务器返回的比对，
     能验证 C++ 里手写的 SHA1 + base64 是对的。
  2. 收 N 帧，校验二进制协议 [4B 长度][JSON][JPEG]，
     并检查 JPEG 的 SOI/EOI 标记是否完整。
  3. 打印每帧的 fps / infer_ms / lat_ms 和检测框数量。
"""
import base64
import hashlib
import json
import os
import socket
import struct
import sys
import time

HOST = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1"
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8000
NFRAMES = int(sys.argv[3]) if len(sys.argv) > 3 else 3
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


class Conn:
    def __init__(self, host, port):
        self.s = socket.create_connection((host, port), timeout=10)
        self.buf = b""

    def send(self, data):
        self.s.sendall(data)

    def read_exact(self, n):
        while len(self.buf) < n:
            chunk = self.s.recv(65536)
            if not chunk:
                raise RuntimeError("连接被关闭")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def read_until(self, marker):
        while marker not in self.buf:
            chunk = self.s.recv(65536)
            if not chunk:
                raise RuntimeError("连接被关闭")
            self.buf += chunk
        out, _, self.buf = self.buf.partition(marker)
        return out + marker

    def close(self):
        self.s.close()


def main():
    key = base64.b64encode(os.urandom(16)).decode()
    expect = base64.b64encode(hashlib.sha1((key + GUID).encode()).digest()).decode()

    c = Conn(HOST, PORT)
    c.send((
        f"GET /ws HTTP/1.1\r\nHost: {HOST}:{PORT}\r\nUpgrade: websocket\r\n"
        f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\n"
        f"Sec-WebSocket-Version: 13\r\n\r\n"
    ).encode())
    head = c.read_until(b"\r\n\r\n").decode(errors="replace")
    first = head.split("\r\n")[0]
    print("握手:", first)

    accept = ""
    for line in head.split("\r\n"):
        if line.lower().startswith("sec-websocket-accept:"):
            accept = line.split(":", 1)[1].strip()
    print("Accept 校验:", "通过" if accept == expect else f"失败 (期望 {expect} 得到 {accept})")
    if accept != expect:
        return 1

    for i in range(NFRAMES):
        b1 = c.read_exact(2)
        op = b1[0] & 0x0F
        ln = b1[1] & 0x7F
        if ln == 126:
            ln = struct.unpack(">H", c.read_exact(2))[0]
        elif ln == 127:
            ln = struct.unpack(">Q", c.read_exact(8))[0]
        payload = c.read_exact(ln)

        hlen = struct.unpack("<I", payload[:4])[0]
        meta = json.loads(payload[4:4 + hlen].decode())
        jpeg = payload[4 + hlen:]
        ok_jpeg = jpeg[:2] == b"\xff\xd8" and jpeg[-2:] == b"\xff\xd9"
        names = [d["name"] for d in meta["dets"]]
        print(
            f"帧{i + 1}: op=0x{op:x} 长度={len(payload)} 头部={hlen}B "
            f"{meta['w']}x{meta['h']} 框={len(meta['dets'])}{names if names else ''} "
            f"fps={meta['fps']} 推理={meta['infer_ms']}ms 延迟={meta['lat_ms']}ms "
            f"JPEG完整={'是' if ok_jpeg else '否'}"
        )
        if not ok_jpeg:
            print("  JPEG 不完整，帧头:", jpeg[:8].hex(), "帧尾:", jpeg[-8:].hex())
            return 1
        time.sleep(0.2)

    c.close()
    print("全部通过")
    return 0


if __name__ == "__main__":
    sys.exit(main())
