package com.galois.cryptol.client;

import java.util.*;
import java.util.function.*;
import java.io.*;

import com.eclipsesource.json.*;

import com.galois.cryptol.client.connection.*;
import com.galois.cryptol.client.connection.json.*;
import com.galois.cryptol.client.connection.netstring.*;

public class CryptolConnection {

    private final Connection connection;
    private final OutputStream output;
    private final InputStream input;

    private volatile boolean closed = false;

    public CryptolConnection(OutputStream output, InputStream input) {
        this.output = output;
        this.input = input;
        // Set up source and sink for connection
        Pipe<JsonValue> pipe =
            new JsonPipe(new NetstringPipe(input, output));
        Function<Exception, Boolean> logAndQuit =
            e -> { System.err.println(e); return false; };
        // Initialize the connection
        connection = new Connection(pipe, logAndQuit);
    }

    // Close the connection
    public synchronized void close() throws IOException {
        if (closed == false) {
            output.close();
            input.close();
            connection.close();
            closed = true;
        }
    }

    // Since this runs on actual output/input streams, we know that connection
    // exceptions in this case are really IOExceptions, so we use this wrapper
    // to allow the caller to not need to see ConnectionExceptions
    private <O> O call(String method, JsonValue params,
                       Function<JsonValue, O> decode)
        throws IOException {
        try {
            Call<O, IOException> call =
                new Call<O, IOException>(method, params, decode, e -> {
                        // handle Cryptol exceptions
                        return null; // FIXME, return structured Cryptol exceptions
                });
            return connection.call(call);
        } catch (ConnectionException e) {
            throw new IOException(e);
        }
    }

    // The calls available:

    public void loadModule(String file) throws IOException {
        call("load module",
             Json.object().add("file", file),
             v -> new Unit());
    }

    public String evalExpr(String expr) throws IOException {
        return call("evaluate expression",
                    Json.object().add("expression", expr),
                    v -> v.toString());
    }
}
