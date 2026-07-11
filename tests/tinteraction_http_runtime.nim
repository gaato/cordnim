import std/[assertions, json, strutils, times]

import chronos
import chronos/apps/http/httpclient

import cordnim/[app, commands]
import cordnim/interactions/[http_runtime, verification]

type RuntimeServices = object

proc acceptingVerifier(publicKey, signature, message: openArray[byte]): bool
    {.gcsafe, raises: [].} =
  publicKey.len == 32 and signature.len == 64 and message.len > 0

proc scenario(): Future[void] {.async.} =
  let application = newDiscordApp(
    RuntimeServices(),
    initAppConfig(ingressHttp),
    initCommandSet[RuntimeServices]())
  let runtime = newInteractionHttpRuntime(
    application,
    initTAddress("127.0.0.1:0"),
    VerificationConfig(
      allowedSkewSeconds: 300,
      maxBodyBytes: 1_024,
      verifier: acceptingVerifier),
    discordApiBaseUrl = "http://127.0.0.1:1")

  doAssert application.hasLifecycle
  await application.start()
  doAssert application.lifecycleState == alsRunning

  let session = HttpSessionRef.new({HttpClientFlag.Http11Pipeline})
  let request = HttpClientRequestRef.new(
    session,
    "http://" & $runtime.localAddress() & "/interactions",
    MethodPost,
    headers = [
      ("Content-Type", "application/json"),
      ("X-Signature-Ed25519", repeat('a', 128)),
      ("X-Signature-Timestamp", $getTime().toUnix())],
    body = @[byte '{', byte '"', byte 't', byte 'y', byte 'p', byte 'e',
      byte '"', byte ':', byte '1', byte '}']).get()
  let response = await request.fetch()
  var body = newString(response.data.len)
  for index, value in response.data:
    body[index] = char(value)
  doAssert response.status == 200
  doAssert parseJson(body)["type"].getInt() == 1
  await request.closeWait()
  await session.closeWait()

  await application.close()
  doAssert application.lifecycleState == alsClosed

waitFor scenario()

block hybrid_requires_a_composite_runtime:
  let application = newDiscordApp(
    RuntimeServices(),
    initAppConfig(ingressHttp, gatewaySubscriptions({giGuildVoiceStates})),
    initCommandSet[RuntimeServices]())
  doAssertRaises ValueError:
    discard newInteractionHttpRuntime(
      application,
      initTAddress("127.0.0.1:0"),
      VerificationConfig(
        allowedSkewSeconds: 300,
        maxBodyBytes: 1_024,
        verifier: acceptingVerifier),
      discordApiBaseUrl = "http://127.0.0.1:1")
