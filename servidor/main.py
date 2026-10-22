"""Servidor de sinalização (FastAPI + WebSocket).

- Login por token: cada token corresponde a um papel (robô, operador ou cliente).
- Repassa SDP (offer/answer) e ICE entre o robô e seu parceiro da vez.
- Comandos de sessão (RF06): iniciar/encerrar, e o fluxo de atendimento do cliente
  (pedir -> operador aceita/recusa). As regras ficam em servidor/sala.py.
- Serve as páginas: /operador (supervisão) e /cliente (atendimento).
"""
import asyncio
import hmac
import logging
from pathlib import Path
from typing import Optional

import uvicorn
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles

from comum import config
from .sala import Sala

log = logging.getLogger("servidor")

app = FastAPI(title="Sinalização de teleoperação")
sala = Sala()


def autenticar(token: str) -> Optional[str]:
    """Compara em tempo constante e devolve o papel, ou None."""
    papel = None
    for esperado, nome in ((config.TOKEN_ROBO, "robo"),
                           (config.TOKEN_OPERADOR, "operador"),
                           (config.TOKEN_CLIENTE, "cliente")):
        if hmac.compare_digest(token.encode(), esperado.encode()) and papel is None:
            papel = nome
    return papel


@app.websocket("/ws")
async def sinalizacao(websocket: WebSocket, token: str = "") -> None:
    await websocket.accept()

    papel = autenticar(token)
    if papel is None:
        log.warning("login recusado (token inválido)")
        await asyncio.sleep(1)  # freia tentativas em força bruta quando exposto à internet
        await websocket.close(code=4401)
        return

    if not await sala.conectar(papel, websocket):
        log.info("cliente recusado: já existe um cliente em atendimento")
        await websocket.close(code=4409)
        return
    log.info("%s conectado", papel)

    try:
        while True:
            await sala.tratar(papel, await websocket.receive_text())
    except WebSocketDisconnect:
        pass
    except Exception:
        log.exception("erro na conexão de %s", papel)
    finally:
        await sala.desconectar(papel, websocket)
        log.info("%s desconectado", papel)


@app.get("/")
async def raiz():
    return RedirectResponse("/operador/")


_raiz = Path(__file__).resolve().parent.parent
app.mount("/operador", StaticFiles(directory=_raiz / "operador", html=True), name="operador")
app.mount("/cliente", StaticFiles(directory=_raiz / "cliente", html=True), name="cliente")


def executar() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    padroes = (config.TOKEN_ROBO == config.TOKEN_PADRAO_ROBO
               or config.TOKEN_OPERADOR == config.TOKEN_PADRAO_OPERADOR
               or config.TOKEN_CLIENTE == config.TOKEN_PADRAO_CLIENTE)
    if padroes:
        log.warning("Usando tokens padrão! Defina TOKEN_ROBO, TOKEN_OPERADOR e TOKEN_CLIENTE "
                    "antes de expor o servidor.")
    if len({config.TOKEN_ROBO, config.TOKEN_OPERADOR, config.TOKEN_CLIENTE}) < 3:
        log.error("Os três tokens precisam ser DIFERENTES entre si.")
    kwargs = {}
    if config.SSL_CERT and config.SSL_KEY:
        kwargs = {"ssl_certfile": config.SSL_CERT, "ssl_keyfile": config.SSL_KEY}
    uvicorn.run(app, host=config.SERVIDOR_HOST, port=config.SERVIDOR_PORTA, log_level="info", **kwargs)


if __name__ == "__main__":
    executar()
