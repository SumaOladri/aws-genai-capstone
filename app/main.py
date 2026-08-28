import logging

from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

from app import auth
from app.bedrock import generate_recipe

logger = logging.getLogger()
logger.setLevel(logging.INFO)

app = FastAPI(title="Recipe AI")
templates = Jinja2Templates(directory="app/templates")

SESSION_COOKIE = "id_token"
ACCESS_COOKIE = "access_token"
COOKIE_MAX_AGE = 3600  # matches the 1-hour token validity

COOKIE_OPTS = {
    "max_age": COOKIE_MAX_AGE,
    "httponly": True,
    "secure": True,
    "samesite": "lax",
}


def current_user(request: Request) -> dict | None:
    """Return the signed-in user's claims, or None."""
    id_token = request.cookies.get(SESSION_COOKIE)
    access_token = request.cookies.get(ACCESS_COOKIE)

    if not id_token:
        logger.info("No session cookie. Cookies present: %s", list(request.cookies))
        return None

    return auth.verify_token(id_token, access_token)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/login")
def login():
    return RedirectResponse(auth.login_url(), status_code=302)


@app.get("/callback")
def callback(code: str | None = None, error: str | None = None):
    if error or not code:
        logger.error("Callback received error=%s code=%s", error, bool(code))
        return RedirectResponse("/?auth_error=1", status_code=302)

    try:
        tokens = auth.exchange_code(code)
    except Exception as exc:
        logger.error("Token exchange failed: %s: %s", type(exc).__name__, exc)
        return RedirectResponse("/?auth_error=1", status_code=302)

    response = RedirectResponse("/", status_code=302)
    response.set_cookie(SESSION_COOKIE, tokens["id_token"], **COOKIE_OPTS)
    response.set_cookie(ACCESS_COOKIE, tokens["access_token"], **COOKIE_OPTS)
    return response


@app.get("/logout")
def logout():
    response = RedirectResponse(auth.logout_url(), status_code=302)
    response.delete_cookie(SESSION_COOKIE)
    response.delete_cookie(ACCESS_COOKIE)
    return response


@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    user = current_user(request)
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "user": user,
            "result": None,
            "error": None,
            "submitted": "",
            "auth_error": request.query_params.get("auth_error"),
        },
    )


@app.post("/generate", response_class=HTMLResponse)
def generate(request: Request, ingredients: str = Form(...)):
    user = current_user(request)
    if not user:
        return RedirectResponse("/login", status_code=302)

    items = [i.strip() for i in ingredients.split(",") if i.strip()]

    if not items:
        return templates.TemplateResponse(
            "index.html",
            {
                "request": request,
                "user": user,
                "result": None,
                "error": "Please enter at least one ingredient.",
                "submitted": ingredients,
            },
        )

    try:
        result = generate_recipe(items)
        error = None
    except Exception as exc:
        logger.error("Recipe generation failed: %s: %s", type(exc).__name__, exc)
        result = None
        error = f"Could not generate a recipe: {exc}"

    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "user": user,
            "result": result,
            "error": error,
            "submitted": ingredients,
        },
    )