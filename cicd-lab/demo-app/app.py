import os

from flask import Flask, jsonify

app = Flask(__name__)
VERSION = os.getenv("APP_VERSION", "v1")


@app.route("/")
def index():
    return f"demo-app {VERSION} — rodando via pipeline Forgejo + Jenkins\n"


@app.route("/health")
def health():
    return jsonify(status="ok", version=VERSION)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=80)
