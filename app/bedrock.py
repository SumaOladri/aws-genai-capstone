import json
import os

import boto3

MODEL_ID = os.environ.get("MODEL_ID", "us.amazon.nova-lite-v1:0")
REGION = os.environ.get("AWS_REGION", "us-east-1")
USE_MOCK = os.environ.get("USE_MOCK", "true").lower() == "true"


def _mock_recipe(ingredients: list[str]) -> str:
    joined = ", ".join(ingredients)
    return f"""# Skillet {ingredients[0].title() if ingredients else "Surprise"}

**Ingredients:** {joined}, olive oil, salt, pepper

**Steps**

1. Heat a tablespoon of oil in a wide pan over medium-high heat.
2. Add {ingredients[0] if ingredients else "your main ingredient"} and sear until browned, about 5 minutes.
3. Stir in the remaining ingredients ({joined}) and season with salt and pepper.
4. Lower the heat, cover, and cook for 15 minutes until everything is tender.
5. Rest for 5 minutes before serving.

_(Mock response — set USE_MOCK=false once Bedrock access is granted.)_
"""


def generate_recipe(ingredients: list[str]) -> str:
    """Ask the model for a recipe built from the given ingredients."""
    if USE_MOCK:
        return _mock_recipe(ingredients)

    client = boto3.client("bedrock-runtime", region_name=REGION)

    prompt = (
        "Suggest a recipe idea using these ingredients: "
        f"{', '.join(ingredients)}. "
        "Include a short ingredient list and numbered steps."
    )

    response = client.invoke_model(
        modelId=MODEL_ID,
        body=json.dumps(
            {
                "anthropic_version": "bedrock-2023-05-31",
                "max_tokens": 1000,
                "messages": [{"role": "user", "content": prompt}],
            }
        ),
    )

    payload = json.loads(response["body"].read())
    return payload["content"][0]["text"]