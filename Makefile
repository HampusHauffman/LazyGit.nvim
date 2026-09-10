.PHONY: test smoke

test:
	nvim --headless -u NONE -i NONE -n -l tests/run.lua

smoke:
	nvim --headless -u NONE -i NONE -n -l tests/smoke.lua
