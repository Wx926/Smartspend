import os
from supabase import create_client, Client

_supabase_client: Client | None = None
_category_cache: dict[str, str] | None = None  # name (lowercase) -> id


def get_supabase() -> Client:
    """Lazily create and return a single shared Supabase client."""
    global _supabase_client
    if _supabase_client is None:
        url = os.environ.get("SUPABASE_URL")
        key = os.environ.get("SUPABASE_KEY")
        if not url or not key:
            raise RuntimeError(
                "SUPABASE_URL / SUPABASE_KEY missing from .env — "
                "ask your teammate for the project URL + anon/service key."
            )
        _supabase_client = create_client(url, key)
    return _supabase_client


def get_category_map(force_refresh: bool = False) -> dict[str, str]:
    """
    Returns a dict mapping lowercase category name -> category_id (UUID).
    Cached after first call since categories rarely change.
    """
    global _category_cache
    if _category_cache is not None and not force_refresh:
        return _category_cache

    supabase = get_supabase()
    response = (
        supabase.table("categories")
        .select("id, name, type")
        .eq("type", "expense")
        .execute()
    )

    _category_cache = {row["name"].lower(): row["id"] for row in response.data}
    return _category_cache


def get_category_id(category_name: str) -> str | None:
    """Look up a category_id by name (case-insensitive). Returns None if not found."""
    category_map = get_category_map()
    return category_map.get(category_name.lower())
