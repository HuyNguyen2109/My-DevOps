# Use a lightweight base image with Python
FROM python:3.11-slim

# Set working directory
WORKDIR /app

# Copy app code
COPY app.py .

# Install dependencies (Flask + requests)
RUN pip install --no-cache-dir flask requests

# Expose the app port
EXPOSE 5001

# Run the app
CMD ["python", "app.py"]
