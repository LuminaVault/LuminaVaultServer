package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const chunkSize = int64(8 * 1024 * 1024)

type createResponse struct {
	ID             string `json:"id"`
	ChunkSizeBytes int64  `json:"chunkSizeBytes"`
	Items          []struct {
		ID string `json:"id"`
	} `json:"items"`
}

func main() {
	baseURL := flag.String("base-url", "http://localhost:8080", "API or load-balancer origin")
	token := flag.String("token", "", "tenant bearer token")
	filePath := flag.String("file", "", "source file; sparse multi-GiB files are supported")
	workers := flag.Int("workers", 4, "concurrent batches")
	timeout := flag.Duration("timeout", 2*time.Hour, "per-worker timeout")
	flag.Parse()
	if *token == "" || *filePath == "" || *workers < 1 {
		flag.Usage()
		os.Exit(2)
	}
	info, err := os.Stat(*filePath)
	must(err)
	client := &http.Client{Transport: &http.Transport{
		MaxIdleConns:        *workers * 2,
		MaxIdleConnsPerHost: *workers * 2,
		IdleConnTimeout:     90 * time.Second,
	}}
	started := time.Now()
	var wg sync.WaitGroup
	errors := make(chan error, *workers)
	for worker := 0; worker < *workers; worker++ {
		wg.Add(1)
		go func(worker int) {
			defer wg.Done()
			ctx, cancel := context.WithTimeout(context.Background(), *timeout)
			defer cancel()
			if err := run(ctx, client, *baseURL, *token, *filePath, info, worker); err != nil {
				errors <- fmt.Errorf("worker %d: %w", worker, err)
			}
		}(worker)
	}
	wg.Wait()
	close(errors)
	failed := false
	for err := range errors {
		failed = true
		fmt.Fprintln(os.Stderr, err)
	}
	if failed {
		os.Exit(1)
	}
	fmt.Printf("completed %d batches of %.2f GiB in %s\n", *workers, float64(info.Size())/(1<<30), time.Since(started))
}

func run(ctx context.Context, client *http.Client, baseURL, token, path string, info os.FileInfo, worker int) error {
	input := map[string]any{"items": []map[string]any{{
		"kind": "file", "fileName": fmt.Sprintf("load-%d-%s", worker, filepath.Base(path)),
		"contentType": "application/octet-stream", "sizeBytes": info.Size(),
	}}}
	payload, _ := json.Marshal(input)
	var batch createResponse
	if err := jsonRequest(ctx, client, http.MethodPost, baseURL+"/v1/ingestions", token, bytes.NewReader(payload), &batch); err != nil {
		return err
	}
	if len(batch.Items) != 1 {
		return fmt.Errorf("create returned %d items", len(batch.Items))
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	defer file.Close()
	size := batch.ChunkSizeBytes
	if size <= 0 || size > chunkSize {
		return fmt.Errorf("unsafe server chunk size %d", size)
	}
	for offset, index := int64(0), 0; offset < info.Size(); offset, index = offset+size, index+1 {
		length := min(size, info.Size()-offset)
		body := io.NewSectionReader(file, offset, length)
		url := fmt.Sprintf("%s/v1/ingestions/%s/items/%s/chunks/%d", baseURL, batch.ID, batch.Items[0].ID, index)
		if err := rawRequest(ctx, client, http.MethodPut, url, token, body, length); err != nil {
			return err
		}
	}
	url := fmt.Sprintf("%s/v1/ingestions/%s/items/%s/complete", baseURL, batch.ID, batch.Items[0].ID)
	return rawRequest(ctx, client, http.MethodPost, url, token, http.NoBody, 0)
}

func jsonRequest(ctx context.Context, client *http.Client, method, url, token string, body io.Reader, output any) error {
	req, err := http.NewRequestWithContext(ctx, method, url, body)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		message, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("%s: %s", resp.Status, message)
	}
	return json.NewDecoder(resp.Body).Decode(output)
}

func rawRequest(ctx context.Context, client *http.Client, method, url, token string, body io.Reader, length int64) error {
	req, err := http.NewRequestWithContext(ctx, method, url, body)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/octet-stream")
	req.ContentLength = length
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		message, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		return fmt.Errorf("%s: %s", resp.Status, message)
	}
	return nil
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
