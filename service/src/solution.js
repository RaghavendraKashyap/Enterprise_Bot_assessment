
require("dotenv").config();

const express = require("express");
const os = require("os");

const app = express();

const APP_NAME = process.env.APP_NAME;
const VERSION = process.env.VERSION;
const PORT = process.env.PORT;

//get
app.get("/", (req, res) => {
    res.status(200).json({
        app: process.env.APP_NAME || APP_NAME,
        version: process.env.VERSION || VERSION,
        pod: os.hostname()
    });
});

//healthceck
app.get("/healthz", (req, res) => {
    res.status(200).json({
        status: "healthy"
    });
});

app.listen(PORT, "0.0.0.0", () => {
    console.log(`Server running on port ${PORT}`);
});
