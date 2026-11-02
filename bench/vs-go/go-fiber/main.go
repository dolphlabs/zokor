// Go Fiber (fasthttp underneath), the same three endpoints as the zokor
// and stdlib net/http servers next to this one, for the "benchmarks
// against Go" todo item -- Fiber because it is the other server the
// todo names, and because it is the framework people reach for over
// net/http specifically for speed, which is the comparison that matters.
package main

import (
	"os"

	"github.com/gofiber/fiber/v2"
)

type user struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type echoBody struct {
	Message string `json:"message"`
}

func main() {
	app := fiber.New(fiber.Config{
		DisableStartupMessage: true,
	})

	app.Get("/", func(c *fiber.Ctx) error {
		c.Set("Content-Type", "text/plain; charset=utf-8")
		return c.Status(fiber.StatusOK).SendString("Hello, World!")
	})

	app.Get("/users/:id", func(c *fiber.Ctx) error {
		id := c.Params("id")
		return c.Status(fiber.StatusOK).JSON(user{ID: id, Name: "user " + id})
	})

	app.Post("/echo", func(c *fiber.Ctx) error {
		var body echoBody
		if err := c.BodyParser(&body); err != nil {
			c.Set("Content-Type", "text/plain; charset=utf-8")
			return c.Status(fiber.StatusBadRequest).SendString("bad json: " + err.Error())
		}
		return c.Status(fiber.StatusOK).JSON(echoBody{Message: body.Message})
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8083"
	}
	app.Listen("127.0.0.1:" + port)
}
