// Go's stdlib net/http, the same three endpoints as the zokor and Fiber
// servers next to this one, for the "benchmarks against Go" todo item.
// Go 1.22+'s enhanced ServeMux gives path variables without a third-party
// router, so this stays stdlib-only.
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
)

type user struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type echoBody struct {
	Message string `json:"message"`
}

func hello(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	w.Write([]byte("Hello, World!"))
}

func getUser(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(user{ID: id, Name: "user " + id})
}

func echo(w http.ResponseWriter, r *http.Request) {
	var body echoBody
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte("bad json: " + err.Error()))
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	json.NewEncoder(w).Encode(echoBody{Message: body.Message})
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "8082"
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /", hello)
	mux.HandleFunc("GET /users/{id}", getUser)
	mux.HandleFunc("POST /echo", echo)
	log.Println("go net/http bench listening on :" + port)
	log.Fatal(http.ListenAndServe("127.0.0.1:"+port, mux))
}
