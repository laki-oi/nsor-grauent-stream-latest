#!/usr/bin/env python3
"""
Universal RFB / VNC Compatibility Bridge for macOS Screen Sharing
Author: Antigravity AI Engineering
Bridges standard VNC clients (Remmina, TigerVNC, noVNC, etc.) to macOS Screen Sharing.
macOS native Screen Sharing advertises Apple Remote Desktop (ARD) security types
(30, 33, 36) which cause Remmina/libvncclient to fail with "Could not authenticate"
and causes noVNC to crash with WebCrypto subtle errors on plain HTTP.
This bridge intercepts the security type list and presents strictly Type 2 (VNC Authentication),
enabling seamless, zero-error connections with standard VNC passwords.
"""

import sys
import socket
import select
import threading
import logging

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s [%(levelname)s] [vnc_bridge] %(message)s'
)

LISTEN_HOST = '0.0.0.0'
LISTEN_PORT = 5901
TARGET_HOST = '127.0.0.1'
TARGET_PORT = 5900
BUFFER_SIZE = 65536


def handle_client(client_sock, client_addr):
    logging.info(f"Incoming connection from {client_addr[0]}:{client_addr[1]}")
    server_sock = None
    try:
        server_sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_sock.settimeout(15)
        server_sock.connect((TARGET_HOST, TARGET_PORT))

        # 1. Protocol Version Exchange
        server_ver = server_sock.recv(12)
        if len(server_ver) < 12 or not server_ver.startswith(b'RFB '):
            logging.error(f"Invalid server version banner: {server_ver}")
            return
        client_sock.sendall(server_ver)

        client_ver = client_sock.recv(12)
        if len(client_ver) < 12 or not client_ver.startswith(b'RFB '):
            logging.error(f"Invalid client version banner: {client_ver}")
            return
        server_sock.sendall(client_ver)

        # 2. Security Types Negotiation
        # Parse client major/minor version (e.g. RFB 003.008\n)
        try:
            ver_str = client_ver.decode('ascii', 'ignore').strip()
            parts = ver_str.split(' ')[1].split('.')
            client_major = int(parts[0])
            client_minor = int(parts[1])
        except Exception:
            client_major, client_minor = 3, 8

        if client_major >= 3 and client_minor >= 7:
            # Server sends number of security types (1 byte) + types
            num_types_raw = server_sock.recv(1)
            if not num_types_raw:
                return
            num_types = num_types_raw[0]
            if num_types == 0:
                # Connection failed from server side (error reason follows)
                reason_len = int.from_bytes(server_sock.recv(4), 'big')
                reason = server_sock.recv(reason_len)
                client_sock.sendall(num_types_raw + int.to_bytes(reason_len, 4, 'big') + reason)
                return

            server_types = server_sock.recv(num_types)
            logging.info(f"Server offered security types: {list(server_types)}")

            # Offer ONLY Type 2 (Standard VNC Authentication) to client
            client_sock.sendall(bytes([1, 2]))
            client_choice = client_sock.recv(1)
            logging.info(f"Client selected security type: {list(client_choice)}")
            server_sock.sendall(client_choice)
        else:
            # RFB 3.3 mode
            sec_type = server_sock.recv(4)
            client_sock.sendall(sec_type)

        # 3. Authentication Challenge & Response
        # macOS VNC sends 16-byte random challenge
        challenge = server_sock.recv(16)
        if len(challenge) < 16:
            logging.error(f"Incomplete challenge from server: {len(challenge)} bytes")
            return
        client_sock.sendall(challenge)

        response = client_sock.recv(16)
        if len(response) < 16:
            logging.error(f"Incomplete response from client: {len(response)} bytes")
            return
        server_sock.sendall(response)

        # 4. Security Result
        auth_result = server_sock.recv(4)
        if len(auth_result) < 4:
            logging.error("No auth result from server")
            return
        client_sock.sendall(auth_result)

        code = int.from_bytes(auth_result, 'big')
        if code != 0:
            logging.warning(f"VNC Authentication failed (code: {code})")
            if client_minor >= 8:
                reason_len = int.from_bytes(server_sock.recv(4), 'big')
                reason = server_sock.recv(reason_len)
                client_sock.sendall(int.to_bytes(reason_len, 4, 'big') + reason)
            return

        logging.info(f"VNC Authentication SUCCEEDED for {client_addr[0]}:{client_addr[1]}! Streaming session...")

        # 5. Raw Bi-directional Streaming
        client_sock.setblocking(True)
        server_sock.setblocking(True)
        sockets = [client_sock, server_sock]

        while True:
            rlist, _, xlist = select.select(sockets, [], sockets, 60.0)
            if xlist:
                break
            if not rlist:
                continue

            for s in rlist:
                other = server_sock if s is client_sock else client_sock
                try:
                    data = s.recv(BUFFER_SIZE)
                    if not data:
                        return
                    other.sendall(data)
                except (socket.error, ConnectionResetError, BrokenPipeError):
                    return

    except Exception as e:
        logging.debug(f"Session closed with error: {e}")
    finally:
        try:
            client_sock.close()
        except Exception:
            pass
        if server_sock:
            try:
                server_sock.close()
            except Exception:
                pass
        logging.info(f"Session ended for {client_addr[0]}:{client_addr[1]}")


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else LISTEN_PORT
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)

    try:
        server.bind((LISTEN_HOST, port))
    except Exception as e:
        logging.error(f"Failed to bind to {LISTEN_HOST}:{port} - {e}")
        sys.exit(1)

    server.listen(64)
    logging.info(f"🍏 Universal RFB / VNC Bridge active on {LISTEN_HOST}:{port} -> {TARGET_HOST}:{TARGET_PORT}")

    while True:
        try:
            client_sock, client_addr = server.accept()
            client_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            t = threading.Thread(target=handle_client, args=(client_sock, client_addr), daemon=True)
            t.start()
        except KeyboardInterrupt:
            logging.info("Shutting down bridge...")
            break
        except Exception as e:
            logging.error(f"Accept error: {e}")

    server.close()


if __name__ == '__main__':
    main()
