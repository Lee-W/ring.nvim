.PHONY: test format format-check

test:
	nvim --headless -u NONE -l tests/test_ring.lua

format:
	stylua lua plugin tests

format-check:
	stylua --check lua plugin tests
