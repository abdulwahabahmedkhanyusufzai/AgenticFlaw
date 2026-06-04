import httpx

def create_authenticated_client(*args, **kwargs):
    # Bypass Google Cloud OIDC auth for local Droplet deployment
    return httpx.AsyncClient(timeout=600)
