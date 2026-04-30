# Multi-stage Dockerfile for Affiliate Junction Demo
# Optimized for Kubernetes deployment

# Stage 1: Base Python image with dependencies
FROM python:3.11-slim as base

# Set working directory
WORKDIR /app

# Install system dependencies
RUN apt-get update && apt-get install -y \
    gcc \
    g++ \
    libssl-dev \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements file
COPY requirements.txt .

# Install Python dependencies
RUN pip install --no-cache-dir -r requirements.txt

# Stage 2: Application image
FROM python:3.11-slim as app

# Set working directory
WORKDIR /app

# Install runtime dependencies only
RUN apt-get update && apt-get install -y \
    libssl3 \
    curl \
    && rm -rf /var/lib/apt/lists/*

# Copy Python packages from base stage
COPY --from=base /usr/local/lib/python3.11/site-packages /usr/local/lib/python3.11/site-packages
COPY --from=base /usr/local/bin /usr/local/bin

# Copy application code
COPY affiliate_common/ ./affiliate_common/
COPY web/ ./web/
COPY *.py ./
COPY *.cql ./
COPY *.sql ./

# Create non-root user for security
RUN useradd -m -u 1000 appuser && \
    chown -R appuser:appuser /app

# Switch to non-root user
USER appuser

# Set Python path
ENV PYTHONPATH=/app
ENV PYTHONUNBUFFERED=1

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=40s --retries=3 \
    CMD curl -f http://localhost:10000/health || exit 1

# Default command (can be overridden in K8s manifests)
CMD ["python", "-m", "uvicorn", "web.main:app", "--host", "0.0.0.0", "--port", "10000"]

# Labels for metadata
LABEL maintainer="affiliate-junction-team"
LABEL version="1.0.0"
LABEL description="Affiliate Junction Demo - watsonx.data federated queries"