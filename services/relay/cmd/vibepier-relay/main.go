// SPDX-License-Identifier: MIT
package main

import (
	"github.com/JunWeiUp/vibepier/services/relay/internal/relay"
	"log"
	"os"
)

func main() {
	if err := relay.Run(os.Args[1:]); err != nil {
		log.Fatal(err)
	}
}
