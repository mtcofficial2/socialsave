package providers

import "encoding/json"

func jsonUnmarshal(data []byte, dest any) error {
	return json.Unmarshal(data, dest)
}
