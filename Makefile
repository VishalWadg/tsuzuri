.PHONY: all content-db test-python test-flutter check clean

all: content-db test-python

content-db:
	python3 tools/build_content_db.py --scope joyo

test-python:
	python3 tools/test_content_db.py
	python3 tools/benchmark_matcher.py

test-flutter:
	flutter test

check: content-db test-python test-flutter

clean:
	flutter clean
