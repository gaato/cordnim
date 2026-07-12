## Narrow WebSocket client handshake used by Cordnim's Gateway adapter.
##
## nim-websock 0.4.0's public client is coupled to its unpatched session
## module. Keeping this small client constructor beside the corrected session
## makes the close-frame fix work for downstream packages as well as this repo.

{.push raises: [], gcsafe.}

import std/strformat

import chronos
import httputils
import stew/base64
import websock/[http, types]

import ./websock_session

export types
export http
export websock_session

proc connectWebSocket*(
    host: string | TransportAddress;
    path: string;
    hostName = "";
    secure = false;
    flags: set[TLSFlags] = {};
    version = WSDefaultVersion;
    frameSize = WSDefaultFrameSize;
    onPing: ControlCb = nil;
    onPong: ControlCb = nil;
    onClose: CloseCb = nil;
    rng: RandomBytesRng = bearSslRng(HmacDrbgContext.new()),
): Future[WSSession] {.
    async: (raises: [CancelledError, AsyncStreamError, HttpError,
      TransportError, WebSocketError]).} =
  let
    key = Base64Pad.encode(WebSecKey.random(rng))
    hostname = if hostName.len > 0: hostName else: $host

  var
    connected = false
    client =
      if secure:
        await TlsHttpClient.connect(host, tlsFlags = flags, hostName = hostname)
      else:
        await HttpClient.connect(host)

  let headerData = [
    ("Connection", "Upgrade"),
    ("Upgrade", "websocket"),
    ("Cache-Control", "no-cache"),
    ("Sec-WebSocket-Version", $version),
    ("Sec-WebSocket-Key", key),
    ("Host", hostname),
  ]
  let headers = HttpTable.init(headerData)

  try:
    let response = await client.request(path, headers = headers)
    if response.code != Http101.toInt():
      raise newException(WSFailedUpgradeError,
        &"Server did not reply with a websocket upgrade: " &
        &"Header code: {response.code} Header reason: {response.reason} " &
        &"Address: {client.address}")

    let session = WSSession(
      stream: move(client.stream),
      readyState: ReadyState.Open,
      masked: true,
      extensions: @[],
      rng: rng,
      frameSize: frameSize,
      onPing: onPing,
      onPong: onPong,
      onClose: onClose,
    )
    connected = true
    return session
  finally:
    if not connected:
      await client.closeWait()

{.pop.}
