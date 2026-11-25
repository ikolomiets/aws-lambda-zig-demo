const apiOrigin = document.querySelector('meta[name="operations-api-origin"]').content;
const callback = new URL("/", location.origin).href;
const attemptKey = "electrit.operations.sign-in";
const callbackFields = ["code", "state", "error"];
const maximumAccountId = (1n << 128n) - 2n;
const idleMessage = "Your Operations credential stays in this tab.";

const signInButton = document.querySelector("#sign-in");
const signOutButton = document.querySelector("#sign-out");
const openLookup = document.querySelector("#open-lookup");
const sessionCell = document.querySelector(".session-cell");
const sessionState = document.querySelector("#session-state");
const signInMessage = document.querySelector("#sign-in-message");
const lookup = document.querySelector("#lookup");
const lookupTitle = document.querySelector("#lookup-title");
const lookupForm = document.querySelector("#lookup-form");
const accountInput = document.querySelector("#account-id");
const submitButton = document.querySelector("#submit-lookup");
const operationPanel = document.querySelector("#operation");
const operationId = document.querySelector("#operation-id");
const checkButton = document.querySelector("#check-operation");
const retryButton = document.querySelector("#retry-lookup");
const operationMessage = document.querySelector("#operation-message");
const operationResult = document.querySelector("#operation-result");

let session = null;
let expiryTimer;
let redemption;
let operation = null;
let operationBusy = false;

class ApiError extends Error {
  constructor(status) {
    super(`Operations API returned HTTP ${status}`);
    this.status = status;
  }
}

function updateMessage(element, message, isError = false) {
  element.textContent = message;
  element.toggleAttribute("data-error", isError);
}

function showSignIn(state, message, isError = false) {
  sessionState.textContent = state;
  updateMessage(signInMessage, message, isError);
}

function renderSession() {
  const signedIn = session !== null;
  sessionCell.toggleAttribute("data-connected", signedIn);
  signInButton.hidden = signedIn;
  signInButton.disabled = false;
  signOutButton.hidden = !signedIn;
  openLookup.hidden = !signedIn;
  lookup.hidden = !signedIn;
}

function clearSession(message, focusSignIn = false) {
  clearTimeout(expiryTimer);
  session?.controller.abort();
  session = null;
  operation = null;
  operationBusy = false;
  operationId.textContent = "";
  operationResult.textContent = "";
  operationResult.hidden = true;
  updateMessage(operationMessage, "");
  lookupForm.reset();
  accountInput.setCustomValidity("");
  renderOperation();
  renderSession();
  showSignIn("Signed out", message);
  if (focusSignIn) signInButton.focus();
}

function base64url(bytes) {
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/, "");
}

async function beginSignIn() {
  signInButton.disabled = true;
  showSignIn("Redirecting", "Opening GitHub sign-in through Operations…");
  try {
    sessionStorage.removeItem(attemptKey);
    const state = base64url(crypto.getRandomValues(new Uint8Array(32)));
    const verifier = base64url(crypto.getRandomValues(new Uint8Array(32)));
    const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier));
    const authorize = new URL("/auth/github/authorize", apiOrigin);
    authorize.search = new URLSearchParams({
      redirect_uri: callback,
      state,
      code_challenge: base64url(new Uint8Array(digest)),
      code_challenge_method: "S256",
    });
    sessionStorage.setItem(attemptKey, JSON.stringify({ state, verifier }));
    location.assign(authorize);
  } catch {
    signInButton.disabled = false;
    showSignIn("Signed out", "Could not start sign-in. Open this page over HTTPS with tab storage enabled.", true);
  }
}

async function request(path, { method = "GET", body, token, signal } = {}) {
  const headers = new Headers();
  if (token) headers.set("Authorization", `Bearer ${token}`);
  if (body) headers.set("Content-Type", "application/json");
  const timeout = AbortSignal.timeout(15_000);
  const response = await fetch(new URL(path, apiOrigin), {
    method,
    headers,
    body: body && JSON.stringify(body),
    credentials: "omit",
    cache: "no-store",
    redirect: "error",
    signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
  });
  if (!response.ok) throw new ApiError(response.status);
  return response.json();
}

async function finishSignIn(params) {
  showSignIn("Verifying", "Verifying your sign-in with Operations…");
  redemption = new AbortController();
  const { signal } = redemption;
  try {
    const cleanUrl = new URL(location.href);
    for (const field of callbackFields) cleanUrl.searchParams.delete(field);
    history.replaceState(null, "", cleanUrl);

    const saved = sessionStorage.getItem(attemptKey);
    sessionStorage.removeItem(attemptKey);
    const attempt = saved && JSON.parse(saved);
    const states = params.getAll("state");
    const codes = params.getAll("code");
    const errors = params.getAll("error");
    if (!attempt || states.length !== 1 || states[0] !== attempt.state ||
        !/^[A-Za-z0-9_-]{43}$/.test(attempt.verifier)) {
      showSignIn("Signed out", "This return does not match a sign-in in this tab. Start again here.", true);
      return;
    }
    if (codes.length === 0 && errors.length === 1 && errors[0] === "access_denied") {
      showSignIn("Signed out", "GitHub sign-in was declined. You can try again when ready.");
      return;
    }
    if (codes.length !== 1 || !/^[a-f0-9]{64}$/.test(codes[0]) || errors.length !== 0) {
      showSignIn("Signed out", "The sign-in return is incomplete or invalid. Start sign-in again.", true);
      return;
    }
    const grant = await request("/auth/github/redeem", {
      method: "POST",
      signal,
      body: { code: codes[0], redirect_uri: callback, code_verifier: attempt.verifier },
    });
    if (signal.aborted) return;
    if (grant?.token_type !== "Bearer" || typeof grant.access_token !== "string" ||
        !/^v4\.public\.[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)?$/.test(grant.access_token) ||
        !Number.isInteger(grant.expires_in) || grant.expires_in < 1 || grant.expires_in > 2_147_483) {
      throw new Error("Invalid credential response");
    }
    const lifetime = grant.expires_in * 1000;
    session = {
      token: grant.access_token,
      expiresAt: Date.now() + lifetime,
      controller: new AbortController(),
    };
    expiryTimer = setTimeout(() => clearSession("Your session expired. Sign in again to continue."), lifetime);
    showSignIn("Signed in", "Your Operations session is ready.");
  } catch (error) {
    if (signal.aborted) return;
    const message = error.status === 410
      ? "This sign-in code expired or was already used. Start sign-in again."
      : "Could not complete sign-in with Operations. Start sign-in again.";
    showSignIn("Signed out", message, true);
  } finally {
    redemption = null;
    if (!signal.aborted) renderSession();
  }
}

function renderOperation() {
  operationPanel.hidden = operation === null;
  submitButton.disabled = operationBusy;
  checkButton.disabled = operationBusy;
  retryButton.hidden = !operation?.canRetry;
  retryButton.disabled = operationBusy;
}

async function runOperation(method) {
  if (!session || !operation || operationBusy) return;
  if (Date.now() >= session.expiresAt) {
    clearSession("Your session expired. Sign in again to continue.", true);
    return;
  }

  const activeSession = session;
  const activeOperation = operation;
  const submitting = method === "POST";
  const { id } = activeOperation.input;
  operationBusy = true;
  renderOperation();
  updateMessage(operationMessage, submitting ? "Submitting the lookup…" : "Checking the Operation…");

  try {
    const view = await request(submitting ? "/operations" : `/operations/${id}`, {
      method,
      body: submitting ? activeOperation.input : undefined,
      token: activeSession.token,
      signal: activeSession.controller.signal,
    });
    if (session !== activeSession) return;
    if (view?.id !== id || (view.state !== "SUBMITTED" && view.state !== "COMPLETED")) {
      throw new Error("Invalid Operation view");
    }
    activeOperation.canRetry = false;
    operationResult.textContent = JSON.stringify(view, null, 2);
    operationResult.hidden = false;
    const message = view.state === "COMPLETED"
      ? "The Operation completed. See its Result below."
      : "The Operation is submitted. Check it again for Completion.";
    updateMessage(operationMessage, message);
  } catch (error) {
    if (session !== activeSession) return;
    if (error.status === 401) {
      clearSession("Operations rejected this session. Sign in again to continue.", true);
      return;
    }
    if (submitting) {
      activeOperation.canRetry = error.status === undefined || error.status === 429 || error.status >= 500;
    }
    let message = error instanceof ApiError ? `${error.message}.` : "Could not reach or read the Operations API.";
    if (error.status === 404 && !submitting) message = "Operations could not find this Operation.";
    if (error.status === 429) message += " Wait before trying again.";
    if (submitting && activeOperation.canRetry) message += " Check the Operation or retry with the same UUID.";
    updateMessage(operationMessage, message, true);
  } finally {
    if (session === activeSession) {
      operationBusy = false;
      renderOperation();
    }
  }
}

signInButton.addEventListener("click", beginSignIn);
signOutButton.addEventListener("click", () => clearSession("You signed out of this tab.", true));
openLookup.addEventListener("click", (event) => {
  event.preventDefault();
  lookupTitle.focus({ preventScroll: true });
  lookup.scrollIntoView();
});
checkButton.addEventListener("click", () => runOperation("GET"));
retryButton.addEventListener("click", () => runOperation("POST"));
accountInput.addEventListener("input", () => accountInput.setCustomValidity(""));

lookupForm.addEventListener("submit", (event) => {
  event.preventDefault();
  if (!session || operationBusy) return;
  if (!/^[1-9][0-9]{0,38}$/.test(accountInput.value) || BigInt(accountInput.value) > maximumAccountId) {
    accountInput.setCustomValidity("Enter a valid TigerBeetle account ID with no leading zeros.");
    accountInput.reportValidity();
    return;
  }

  const accountId = accountInput.value;
  if (!operation?.canRetry || operation.accountId !== accountId) {
    operation = {
      accountId,
      input: { id: crypto.randomUUID(), name: "TigerBeetle", body: { lookup_accounts: [{ id: accountId }] } },
      canRetry: false,
    };
    operationId.textContent = operation.input.id;
    operationResult.textContent = "";
    operationResult.hidden = true;
  }
  runOperation("POST");
});

window.addEventListener("pagehide", () => {
  redemption?.abort();
  if (session) clearSession(idleMessage);
});
window.addEventListener("pageshow", (event) => {
  if (event.persisted) clearSession(idleMessage);
});

const params = new URLSearchParams(location.search);
if (callbackFields.some((field) => params.has(field))) {
  finishSignIn(params);
} else {
  renderSession();
}
