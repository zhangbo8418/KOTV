package config

import "testing"

func TestSpiderSpecChanged(t *testing.T) {
	if SpiderSpecChanged(" ./a.jar;md5;1 ", "./a.jar;md5;1") {
		t.Fatal("same jar spec must not restart")
	}
	if !SpiderSpecChanged("./a.jar;md5;1", "./b.jar;md5;2") {
		t.Fatal("different jar spec must restart")
	}
	if SpiderSpecChanged("", "  ") {
		t.Fatal("empty spec must not restart")
	}
}
