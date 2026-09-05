FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .

# Cloud Run injects PORT at runtime. EC2 and local docker don't, and both assume
# 8080 (the ALB health check targets 8080, and userdata.sh maps -p 8080:8080),
# so default to it rather than hardcoding either one.
ENV PORT=8080
EXPOSE 8080

# Shell form so ${PORT} expands; `exec` so gunicorn becomes PID 1 and actually
# receives SIGTERM (Cloud Run sends one before shutting an instance down).
# 120s timeout: 60 was tight enough that a large photo on a small instance could
# be killed mid-strip, which returns an HTML error page instead of JSON.
CMD exec gunicorn -b 0.0.0.0:${PORT} -w 2 --timeout 120 app:app
