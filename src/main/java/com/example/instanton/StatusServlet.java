package com.example.instanton;

import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.lang.management.ManagementFactory;

/**
 * Reports timings that distinguish a restored InstantOn process from a normal start.
 *
 * <p>Liberty loads this class while the application starts. With {@code afterAppStart},
 * that happens during the image build, before {@code checkpoint.sh} freezes the process.
 * Static initialization does not run again on restore, so {@code CLASS_INITIALIZED_AT}
 * stays at the checkpoint time.
 */
@WebServlet(urlPatterns = {"/health", "/status"})
public class StatusServlet extends HttpServlet {

    private static final long CLASS_INITIALIZED_AT = System.currentTimeMillis();

    static {
        System.out.println(
                "INSTANTON_DEMO_CLASS_INIT epochMillis=" + CLASS_INITIALIZED_AT);
    }

    @Override
    protected void doGet(HttpServletRequest request, HttpServletResponse response)
            throws IOException {
        response.setCharacterEncoding("UTF-8");
        response.setContentType("application/json");

        if ("/health".equals(request.getServletPath())) {
            response.getWriter().write("{\"status\":\"UP\"}");
            return;
        }

        long now = System.currentTimeMillis();
        long uptime = ManagementFactory.getRuntimeMXBean().getUptime();
        String hostname = System.getenv("HOSTNAME");
        if (hostname == null || hostname.isBlank()) {
            hostname = "unknown";
        }

        response.getWriter().write(
                "{"
                        + "\"status\":\"UP\","
                        + "\"application\":\"instanton-demo\","
                        + "\"podHostname\":\"" + jsonEscape(hostname) + "\","
                        + "\"requestEpochMillis\":" + now + ","
                        + "\"classInitializedEpochMillis\":" + CLASS_INITIALIZED_AT + ","
                        + "\"millisSinceClassInit\":" + (now - CLASS_INITIALIZED_AT) + ","
                        + "\"jvmUptimeMillis\":" + uptime
                        + "}");
    }

    private static String jsonEscape(String value) {
        return value.replace("\\", "\\\\").replace("\"", "\\\"");
    }
}
