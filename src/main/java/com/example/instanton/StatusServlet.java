package com.example.instanton;

import jakarta.servlet.annotation.WebServlet;
import jakarta.servlet.http.HttpServlet;
import jakarta.servlet.http.HttpServletRequest;
import jakarta.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.lang.management.ManagementFactory;

/**
 * One endpoint for the demo.
 *
 * <p>Liberty loads this class before {@code checkpoint.sh} freezes the process.
 * Static initialization does not run again on restore, so {@code CLASS_INITIALIZED_AT}
 * stays at the checkpoint time while {@code jvmUptimeMillis} starts over in the pod.
 */
@WebServlet("/status")
public class StatusServlet extends HttpServlet {

    private static final long CLASS_INITIALIZED_AT = System.currentTimeMillis();

    static {
        System.out.println("INSTANTON_DEMO_CLASS_INIT epochMillis=" + CLASS_INITIALIZED_AT);
    }

    @Override
    protected void doGet(HttpServletRequest request, HttpServletResponse response)
            throws IOException {
        long now = System.currentTimeMillis();
        response.setContentType("application/json");
        response.getWriter().printf(
                "{\"status\":\"UP\",\"classInitializedEpochMillis\":%d,\"millisSinceClassInit\":%d,\"jvmUptimeMillis\":%d}%n",
                CLASS_INITIALIZED_AT,
                now - CLASS_INITIALIZED_AT,
                ManagementFactory.getRuntimeMXBean().getUptime());
    }
}
