from flask import Flask, Response
import os

app = Flask(__name__)

# Define the path to the file you want to serve
FILE_PATH = os.environ['FILEPATH']

@app.route("/")
def serve_file():
    """
    Serve the contents of the pre-defined file.
    If the file does not exist, return a 404 error.
    """
    if os.path.exists(FILE_PATH):
        with open(FILE_PATH, "r") as file:
            content = file.read()
        return Response(content, mimetype="text/plain")
    else:
        return Response(f"File not found: {FILE_PATH}", status=404, mimetype="text/plain")

if __name__ == "__main__":
    # Run the Flask web server
    app.run(host="0.0.0.0", port=5000)