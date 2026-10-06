#!/usr/bin/env node
"use strict";

require("../lib/cli.cjs")
  .main()
  .catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
