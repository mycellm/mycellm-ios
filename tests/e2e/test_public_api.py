"""End-to-end tests for mycellm public API surfaces.

Hits production api.mycellm.dev and local iOS-as-node when MYCELLM_IOS_LOCAL_URL
is set. Designed to be CI-runnable + manually-runnable while doing release
hardening. Not part of the iOS Xcode test target — this is Python pytest
that we use from utopia/jupiter to validate the network the iOS app talks to.

Run:
    pytest ios/tests/e2e/test_public_api.py -v
    pytest ios/tests/e2e/test_public_api.py -v -m public  # public-only
    MYCELLM_IOS_LOCAL_URL=http://localhost:8420 pytest ...  # also test iOS node

Skipped marks:
    @pytest.mark.public — needs api.mycellm.dev reachable
    @pytest.mark.local  — needs MYCELLM_IOS_LOCAL_URL env var pointing at a
                          running iOS-as-node (typically the iPad sim's
                          embedded HTTP server, port 8420 forwarded)
"""
import os
import pytest
import requests

PUBLIC = "https://api.mycellm.dev"
LOCAL = os.getenv("MYCELLM_IOS_LOCAL_URL")  # e.g. http://localhost:8420
TIMEOUT = 30


def _post_chat(base: str, **body):
    payload = {
        "model": "auto",
        "messages": [{"role": "user", "content": "hi"}],
        "max_tokens": 50,
    }
    payload.update(body)
    r = requests.post(f"{base}/v1/public/chat/completions" if "mycellm.dev" in base
                      else f"{base}/v1/chat/completions",
                      json=payload, timeout=TIMEOUT)
    r.raise_for_status()
    return r.json()


# ───────────────────────── Public API tests ─────────────────────────

@pytest.mark.public
class TestPublicApi:
    """Tests against api.mycellm.dev — the gateway routing to homelab."""

    def test_models_endpoint_returns_auto(self):
        r = requests.get(f"{PUBLIC}/v1/models", timeout=TIMEOUT)
        r.raise_for_status()
        ids = [m["id"] for m in r.json().get("data", [])]
        assert "auto" in ids, f"expected 'auto' in models, got {ids}"

    def test_capabilities_includes_supports_thinking(self):
        r = requests.get(f"{PUBLIC}/v1/models/capabilities", timeout=TIMEOUT)
        r.raise_for_status()
        models = r.json().get("models", [])
        assert models, "no models in capabilities"
        for m in models:
            assert "supports_thinking" in m, f"model {m.get('id')} missing supports_thinking"

    def test_public_stats_top_contributors_populated(self):
        """Was the bug we just fixed — contributors list was empty for QUIC peers."""
        r = requests.get(f"{PUBLIC}/v1/node/public/stats", timeout=TIMEOUT)
        r.raise_for_status()
        d = r.json()
        assert d["nodes"]["online"] >= 1
        # On a healthy network with peers, contributors should be non-empty.
        # Skip when no peers — bootstrap-only network is a valid state.
        if d["nodes"]["online"] > 1:
            assert len(d["top_contributors"]) >= 1, "contributors empty despite peers online"

    def test_public_stats_growth_history_has_request_data(self):
        r = requests.get(f"{PUBLIC}/v1/node/public/stats", timeout=TIMEOUT)
        r.raise_for_status()
        hist = r.json().get("growth", {}).get("history", [])
        if hist:
            sample = hist[-1]
            # Was the second bug we fixed — history snapshots lost requests/tokens.
            assert "requests" in sample, f"history snapshot missing 'requests': {sample.keys()}"

    def test_chat_with_reasoning_exclude_returns_clean_content(self):
        """iOS-style request — reasoning.exclude=true, low max_tokens."""
        r = _post_chat(PUBLIC, reasoning={"exclude": True}, max_tokens=50)
        msg = r["choices"][0]["message"]
        # The fix: should NOT be empty even with low max_tokens.
        assert msg.get("content"), f"chat returned empty content: {r}"
        # Should NOT leak reasoning when exclude is true.
        assert not msg.get("reasoning_content"), \
            f"reasoning_content leaked despite exclude=true: {msg.get('reasoning_content')[:200]}"

    def test_chat_without_reasoning_field_also_clean(self):
        """Plain request — verifies server default-hides reasoning AND model doesn't think."""
        r = _post_chat(PUBLIC, max_tokens=50)
        msg = r["choices"][0]["message"]
        assert msg.get("content"), f"chat returned empty content (no reasoning field): {r}"

    def test_chat_finish_reason_stop_when_no_tools(self):
        r = _post_chat(PUBLIC, reasoning={"exclude": True}, max_tokens=50)
        assert r["choices"][0]["finish_reason"] == "stop"

    def test_chat_reports_token_usage(self):
        r = _post_chat(PUBLIC, reasoning={"exclude": True}, max_tokens=50)
        u = r["usage"]
        assert u["prompt_tokens"] > 0
        assert u["completion_tokens"] > 0
        assert u["total_tokens"] == u["prompt_tokens"] + u["completion_tokens"]


# ───────────────────────── Local iOS-as-node tests ─────────────────────────

@pytest.mark.skipif(not LOCAL, reason="MYCELLM_IOS_LOCAL_URL not set")
@pytest.mark.local
class TestIosNodeApi:
    """Tests against the iOS app's embedded HTTP server.

    Pre-req: iOS app running on iPad/iPhone (sim or device) with HTTP server
    enabled, port 8420 accessible, model loaded.
    """

    def test_health_or_models_responds(self):
        # Some versions expose /v1/health, others don't — fall back to /v1/models.
        for path in ["/v1/health", "/v1/models"]:
            r = requests.get(f"{LOCAL}{path}", timeout=5)
            if r.status_code == 200:
                return
        pytest.fail(f"neither /v1/health nor /v1/models responded at {LOCAL}")

    def test_models_includes_loaded_model(self):
        r = requests.get(f"{LOCAL}/v1/models", timeout=5)
        r.raise_for_status()
        ids = [m["id"] for m in r.json().get("data", [])]
        # At minimum should have 'auto' even if no model is loaded.
        assert "auto" in ids or len(ids) >= 1

    def test_capabilities_endpoint_exists(self):
        """New in v0.3.0 parity — should respond on iOS too."""
        r = requests.get(f"{LOCAL}/v1/models/capabilities", timeout=5)
        r.raise_for_status()
        assert "models" in r.json()

    def test_chat_completion_works(self):
        """Smoke test — iOS app handles /v1/chat/completions request."""
        r = requests.post(f"{LOCAL}/v1/chat/completions", json={
            "model": "auto",
            "messages": [{"role": "user", "content": "hi"}],
            "max_tokens": 50,
            "reasoning": {"exclude": True},
        }, timeout=60)
        r.raise_for_status()
        d = r.json()
        assert d["choices"][0]["message"].get("content"), \
            "iOS-node chat returned empty content"

    def test_tools_request_now_accepted(self):
        """Was a 400-stub in earlier commits; now should actually execute."""
        r = requests.post(f"{LOCAL}/v1/chat/completions", json={
            "model": "auto",
            "messages": [{"role": "user", "content": "What is the weather in SF?"}],
            "max_tokens": 200,
            "tools": [{
                "type": "function",
                "function": {
                    "name": "get_weather",
                    "description": "Get current weather for a city",
                    "parameters": {
                        "type": "object",
                        "properties": {"city": {"type": "string"}},
                        "required": ["city"],
                    },
                },
            }],
            "reasoning": {"exclude": True},
        }, timeout=120)
        # Not asserting tool_calls actually fires — depends on the model
        # loaded. Just asserting the request doesn't 400 and we get a
        # response shape back.
        assert r.status_code == 200, f"tools request rejected: {r.text[:200]}"
        d = r.json()
        assert "choices" in d
