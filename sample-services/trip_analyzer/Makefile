.PHONY: help install dev test lint format clean

# Default target when you just type 'make'
help:
	@echo "Usage: make <target>"
	@echo ""
	@echo "Targets:"
	@echo "  install     Install dependencies using uv"
	@echo "  dev         Run the FastAPI development server"
	@echo "  test        Run all tests (unit and integration)"
	@echo "  lint        Run ruff check and mypy. (Fix it via uv run ruff check . --fix)"
	@echo "  clean       Remove temporary files and cache"

# 1. Setup & Install
install:
	uv sync

# 2. Development
dev:
	uv run uvicorn trip_analyzer.main:app --host 0.0.0.0 --port 8000 --reload

# 3. Testing
test:
	uv run pytest tests/

test-unit:
	uv run pytest tests/unit

test-integration:
	uv run pytest tests/integration

# 4. Code Quality
lint:
	uv run ruff check .
	uv run mypy src/

generate:
	@echo "Generating gRPC stubs..."
	uv run python -m grpc_tools.protoc \
		-I proto \
		--python_betterproto_out=src/trip_analyzer/client/generated/ \
		proto/*.proto
	@echo "Done."

# 6. Cleanup
clean:
	find . -type d -name "__pycache__" -exec rm -rf {} +
	find . -type d -name ".pytest_cache" -exec rm -rf {} +
	find . -type d -name ".ruff_cache" -exec rm -rf {} +
	find . -type d -name ".mypy_cache" -exec rm -rf {} +