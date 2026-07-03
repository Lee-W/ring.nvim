.PHONY: test format-check

test:
	nvim --headless -u NONE -l tests/test_ring.lua

format-check:
	stylua --check lua plugin tests
