from fastapi import FastAPI, Form, Request
from fastapi.responses import HTMLResponse
from fastapi.templating import Jinja2Templates

from app.bedrock import generate_recipe

app = FastAPI(title="Recipe AI")
templates = Jinja2Templates(directory="app/templates")


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/", response_class=HTMLResponse)
def index(request: Request):
    return templates.TemplateResponse(
        "index.html", {"request": request, "result": None, "submitted": ""}
    )


@app.post("/generate", response_class=HTMLResponse)
def generate(request: Request, ingredients: str = Form(...)):
    items = [i.strip() for i in ingredients.split(",") if i.strip()]

    if not items:
        return templates.TemplateResponse(
            "index.html",
            {
                "request": request,
                "result": None,
                "error": "Please enter at least one ingredient.",
                "submitted": ingredients,
            },
        )

    try:
        result = generate_recipe(items)
        error = None
    except Exception as exc:
        result = None
        error = f"Could not generate a recipe: {exc}"

    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "result": result,
            "error": error,
            "submitted": ingredients,
        },
    )