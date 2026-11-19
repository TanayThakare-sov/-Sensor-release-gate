# Sensor image for the Kubernetes DaemonSet.
FROM ubuntu:22.04
RUN apt-get update \
 && apt-get install -y --no-install-recommends bpftrace python3 libc6-dev linux-libc-dev \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY sensor /app/sensor
EXPOSE 9110
ENTRYPOINT ["python3", "-m", "sensor.agent", "--port", "9110", "--bind", "0.0.0.0"]
