package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/signal"
	"sort"
	"sync"
	"syscall"
	"time"
)

// --url: API端点URL（默认为localhost:8000）
// --model: 模型名称或路径
// --max-tokens: 每个请求生成的最大token数
// --concurrency: 并发客户端数量
// --duration: 测试持续时间（秒）
// --prompt: 用于测试的提示文本
// --prompt-file: 从文件加载提示文本
// --output: 结果CSV文件的保存路径
// CompletionRequest represents the request structure for the LLM API
type CompletionRequest struct {
	Model       string  `json:"model"`
	Prompt      string  `json:"prompt"`
	MaxTokens   int     `json:"max_tokens"`
	Temperature float64 `json:"temperature"`
}

// CompletionChoice represents a single completion choice
type CompletionChoice struct {
	Text         string `json:"text"`
	Index        int    `json:"index"`
	FinishReason string `json:"finish_reason"`
}

// CompletionUsage contains token usage statistics
type CompletionUsage struct {
	PromptTokens     int `json:"prompt_tokens"`
	CompletionTokens int `json:"completion_tokens"`
	TotalTokens      int `json:"total_tokens"`
}

// CompletionResponse represents the API response
type CompletionResponse struct {
	ID      string             `json:"id"`
	Object  string             `json:"object"`
	Created int64              `json:"created"`
	Model   string             `json:"model"`
	Choices []CompletionChoice `json:"choices"`
	Usage   CompletionUsage    `json:"usage"`
}

// TestResult stores result metrics for a single request
type TestResult struct {
	StartTime        time.Time
	EndTime          time.Time
	Duration         time.Duration
	PromptTokens     int
	CompletionTokens int
	TotalTokens      int
	Error            error
}

// TestConfig stores all test configuration
type TestConfig struct {
	ApiURL      string
	Model       string
	Prompt      string
	MaxTokens   int
	Concurrency int
	Duration    time.Duration
	RampUp      time.Duration
	Temperature float64
	OutputFile  string
	Verbose     bool
}

func main() {
	// Parse command line arguments
	apiURL := flag.String("url", "http://153.37.96.42:21006/v1/completions", "API endpoint URL")
	model := flag.String("model", "/home/models/DeepSeek-R1-Int4-AWQ", "Model name/path")
	promptFile := flag.String("prompt-file", "", "File containing prompt text")
	prompt := flag.String("prompt", "Explain quantum computing in simple terms", "Prompt text")
	maxTokens := flag.Int("max-tokens", 1000, "Maximum completion tokens")
	concurrency := flag.Int("concurrency", 100, "Number of concurrent clients")
	duration := flag.Int("duration", 60, "Test duration in seconds")
	rampUp := flag.Int("ramp-up", 5, "Ramp-up period in seconds")
	temperature := flag.Float64("temperature", 0.7, "Generation temperature")
	outputFile := flag.String("output", "llm_test_results.csv", "Output file for detailed results (CSV)")
	verbose := flag.Bool("verbose", true, "Verbose output with real-time stats")
	flag.Parse()

	// Read prompt from file if specified
	if *promptFile != "" {
		data, err := os.ReadFile(*promptFile)
		if err != nil {
			log.Fatalf("Error reading prompt file: %v", err)
		}
		*prompt = string(data)
	}

	// Create test configuration
	config := TestConfig{
		ApiURL:      *apiURL,
		Model:       *model,
		Prompt:      *prompt,
		MaxTokens:   *maxTokens,
		Concurrency: *concurrency,
		Duration:    time.Duration(*duration) * time.Second,
		RampUp:      time.Duration(*rampUp) * time.Second,
		Temperature: *temperature,
		OutputFile:  *outputFile,
		Verbose:     *verbose,
	}

	// Print test configuration
	fmt.Println("=== Load Test Configuration ===")
	fmt.Printf("API URL: %s\n", config.ApiURL)
	fmt.Printf("Model: %s\n", config.Model)
	fmt.Printf("Prompt length: %d characters\n", len(config.Prompt))
	fmt.Printf("Max tokens: %d\n", config.MaxTokens)
	fmt.Printf("Concurrency: %d clients\n", config.Concurrency)
	fmt.Printf("Duration: %s\n", config.Duration)
	fmt.Printf("Ramp-up period: %s\n", config.RampUp)
	fmt.Printf("Temperature: %.2f\n", config.Temperature)
	fmt.Printf("Output file: %s\n", config.OutputFile)
	fmt.Println("===========================")

	// Run the load test
	results := runLoadTest(config)

	// Process and display results
	processResults(results, config)
}

func runLoadTest(config TestConfig) []TestResult {
	// Channel for collecting results
	resultsChan := make(chan TestResult, config.Concurrency*int(config.Duration/time.Second))

	// WaitGroup for worker goroutines
	var wg sync.WaitGroup

	// Create context that can be cancelled
	ctx, cancel := context.WithTimeout(context.Background(), config.Duration)
	defer cancel()

	// Handle OS signals for graceful shutdown
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		sig := <-sigChan
		fmt.Printf("\nReceived signal %v, shutting down...\n", sig)
		cancel()
	}()

	// Track test start time
	testStartTime := time.Now()

	// Start worker goroutines
	for i := 0; i < config.Concurrency; i++ {
		wg.Add(1)

		// Gradually start workers during ramp-up period
		if config.RampUp > 0 && config.Concurrency > 1 {
			rampDelay := time.Duration(float64(config.RampUp) * float64(i) / float64(config.Concurrency-1))
			time.Sleep(rampDelay)
		}

		go func(workerID int) {
			defer wg.Done()
			worker(ctx, workerID, config, resultsChan)
		}(i)
	}

	// Start a goroutine to periodically display stats if verbose mode is enabled
	if config.Verbose {
		ticker := time.NewTicker(3 * time.Second)
		go func() {
			defer ticker.Stop()

			var completedRequests int
			var totalTokens int
			var successfulRequests int
			var failedRequests int

			for {
				select {
				case <-ctx.Done():
					return
				case <-ticker.C:
					elapsedTime := time.Since(testStartTime)
					if elapsedTime.Seconds() > 0 {
						throughput := float64(completedRequests) / elapsedTime.Seconds()
						tokenThroughput := float64(totalTokens) / elapsedTime.Seconds()

						fmt.Printf("\r[%s] Req: %d (%.2f/s), Success: %d, Failed: %d, Tokens: %d (%.2f/s)     ",
							elapsedTime.Round(time.Second),
							completedRequests,
							throughput,
							successfulRequests,
							failedRequests,
							totalTokens,
							tokenThroughput)
					}
				case result := <-resultsChan:
					completedRequests++
					if result.Error == nil {
						successfulRequests++
						totalTokens += result.CompletionTokens
					} else {
						failedRequests++
					}
				}
			}
		}()
	}

	// Collect results without blocking the stat-reporting goroutine
	var results []TestResult
	resultsCollector := make(chan []TestResult)

	go func() {
		var collectedResults []TestResult
		for result := range resultsChan {
			collectedResults = append(collectedResults, result)
		}
		resultsCollector <- collectedResults
	}()

	// Wait for all workers to complete
	go func() {
		wg.Wait()
		close(resultsChan)
	}()

	// Wait for results collection
	results = <-resultsCollector

	if config.Verbose {
		fmt.Println() // Add newline after progress indicators
	}

	return results
}

func worker(ctx context.Context, id int, config TestConfig, results chan<- TestResult) {
	for {
		select {
		case <-ctx.Done():
			return
		default:
			// Send request to the LLM API
			req := CompletionRequest{
				Model:       config.Model,
				Prompt:      config.Prompt,
				MaxTokens:   config.MaxTokens,
				Temperature: config.Temperature,
			}

			startTime := time.Now()
			result := sendRequest(config.ApiURL, req)
			result.StartTime = startTime
			result.EndTime = time.Now()
			result.Duration = result.EndTime.Sub(result.StartTime)

			// Send result to the collector
			results <- result

			// Small pause to prevent hammering the server
			time.Sleep(50 * time.Millisecond)
		}
	}
}

func sendRequest(url string, req CompletionRequest) TestResult {
	result := TestResult{}

	// Convert request to JSON
	reqBody, err := json.Marshal(req)
	if err != nil {
		result.Error = fmt.Errorf("failed to marshal request: %v", err)
		return result
	}

	// Create HTTP request
	httpReq, err := http.NewRequest("POST", url, bytes.NewBuffer(reqBody))
	if err != nil {
		result.Error = fmt.Errorf("failed to create request: %v", err)
		return result
	}

	httpReq.Header.Set("Content-Type", "application/json")

	// Send request
	client := &http.Client{
		Timeout: 120 * time.Second, // 2-minute timeout for long generations
	}

	resp, err := client.Do(httpReq)
	if err != nil {
		result.Error = fmt.Errorf("request failed: %v", err)
		return result
	}
	defer resp.Body.Close()

	// Read response
	respBody, err := io.ReadAll(resp.Body)
	if err != nil {
		result.Error = fmt.Errorf("failed to read response: %v", err)
		return result
	}

	// Check status code
	if resp.StatusCode != http.StatusOK {
		result.Error = fmt.Errorf("API returned status %d: %s", resp.StatusCode, string(respBody))
		return result
	}

	// Parse response
	var completionResp CompletionResponse
	err = json.Unmarshal(respBody, &completionResp)
	if err != nil {
		result.Error = fmt.Errorf("failed to parse response JSON: %v", err)
		return result
	}

	// Extract token counts
	result.PromptTokens = completionResp.Usage.PromptTokens
	result.CompletionTokens = completionResp.Usage.CompletionTokens
	result.TotalTokens = completionResp.Usage.TotalTokens

	return result
}

func processResults(results []TestResult, config TestConfig) {
	// Separate successful and failed requests
	var successfulResults []TestResult
	var failedResults []TestResult

	for _, r := range results {
		if r.Error == nil {
			successfulResults = append(successfulResults, r)
		} else {
			failedResults = append(failedResults, r)
		}
	}

	// Calculate test duration
	var testDuration time.Duration
	if len(results) > 0 {
		minStartTime := results[0].StartTime
		maxEndTime := results[0].EndTime

		for _, r := range results {
			if r.StartTime.Before(minStartTime) {
				minStartTime = r.StartTime
			}
			if r.EndTime.After(maxEndTime) {
				maxEndTime = r.EndTime
			}
		}

		testDuration = maxEndTime.Sub(minStartTime)
	}

	// Calculate total tokens
	var totalPromptTokens int
	var totalCompletionTokens int
	var totalTokens int

	for _, r := range successfulResults {
		totalPromptTokens += r.PromptTokens
		totalCompletionTokens += r.CompletionTokens
		totalTokens += r.TotalTokens
	}

	// Calculate latency percentiles
	if len(successfulResults) > 0 {
		// Sort results by duration
		sort.Slice(successfulResults, func(i, j int) bool {
			return successfulResults[i].Duration < successfulResults[j].Duration
		})

		// Calculate various percentiles
		p50 := percentile(successfulResults, 50)
		p90 := percentile(successfulResults, 90)
		p95 := percentile(successfulResults, 95)
		p99 := percentile(successfulResults, 99)

		// Print results
		fmt.Println("\n=== Test Results ===")
		fmt.Printf("Total requests: %d\n", len(results))
		fmt.Printf("Successful requests: %d\n", len(successfulResults))
		fmt.Printf("Failed requests: %d\n", len(failedResults))
		fmt.Printf("Test duration: %s\n", testDuration.Round(time.Millisecond))

		if len(successfulResults) > 0 {
			fmt.Printf("Average latency: %s\n", avgDuration(successfulResults).Round(time.Millisecond))
			fmt.Printf("Median latency (p50): %s\n", p50.Round(time.Millisecond))
			fmt.Printf("p90 latency: %s\n", p90.Round(time.Millisecond))
			fmt.Printf("p95 latency: %s\n", p95.Round(time.Millisecond))
			fmt.Printf("p99 latency: %s\n", p99.Round(time.Millisecond))

			fmt.Printf("Requests per second: %.2f\n", float64(len(successfulResults))/testDuration.Seconds())
			fmt.Printf("Average tokens per request: %.2f\n", float64(totalCompletionTokens)/float64(len(successfulResults)))
			fmt.Printf("Total completion tokens: %d\n", totalCompletionTokens)
			fmt.Printf("Total input tokens: %d\n", totalPromptTokens)
			fmt.Printf("Tokens per second: %.2f\n", float64(totalCompletionTokens)/testDuration.Seconds())

			// Calculate token generation speed (tokens/second per request)
			var totalTokenSpeed float64
			var validSpeedMeasurements int
			for _, r := range successfulResults {
				if r.Duration > 0 && r.CompletionTokens > 0 {
					tokenSpeed := float64(r.CompletionTokens) / r.Duration.Seconds()
					totalTokenSpeed += tokenSpeed
					validSpeedMeasurements++
				}
			}

			if validSpeedMeasurements > 0 {
				avgTokenSpeed := totalTokenSpeed / float64(validSpeedMeasurements)
				fmt.Printf("Average token generation speed: %.2f tokens/second per request\n", avgTokenSpeed)
			}

			// Calculate max concurrent throughput
			maxTotalTokensPerSecond := float64(totalCompletionTokens) / testDuration.Seconds()
			maxConcurrentThroughput := maxTotalTokensPerSecond * float64(config.Concurrency) / float64(len(successfulResults))
			fmt.Printf("Estimated max concurrent throughput: %.2f tokens/second\n", maxConcurrentThroughput)
		}

		// Write detailed results to file if specified
		if config.OutputFile != "" {
			err := writeResultsToCsv(results, config.OutputFile)
			if err != nil {
				fmt.Printf("Error writing results to file: %v\n", err)
			} else {
				fmt.Printf("Detailed results written to: %s\n", config.OutputFile)
			}
		}

		// Print error distribution if there were failures
		if len(failedResults) > 0 {
			fmt.Println("\nError distribution:")
			errorCounts := make(map[string]int)
			for _, r := range failedResults {
				errorCounts[r.Error.Error()]++
			}

			for errMsg, count := range errorCounts {
				fmt.Printf("  - %s: %d occurrences\n", errMsg, count)
			}
		}
	} else {
		fmt.Println("\nNo successful requests to analyze.")
	}
}

func percentile(results []TestResult, p int) time.Duration {
	if len(results) == 0 {
		return 0
	}

	idx := (len(results) - 1) * p / 100
	return results[idx].Duration
}

func avgDuration(results []TestResult) time.Duration {
	if len(results) == 0 {
		return 0
	}

	var total time.Duration
	for _, r := range results {
		total += r.Duration
	}

	return total / time.Duration(len(results))
}

func writeResultsToCsv(results []TestResult, filename string) error {
	file, err := os.Create(filename)
	if err != nil {
		return err
	}
	defer file.Close()

	// Write header
	_, err = file.WriteString("StartTime,EndTime,DurationMs,PromptTokens,CompletionTokens,TotalTokens,Error\n")
	if err != nil {
		return err
	}

	// Write data rows
	for _, r := range results {
		var errorMsg string
		if r.Error != nil {
			errorMsg = r.Error.Error()
		}

		row := fmt.Sprintf("%s,%s,%d,%d,%d,%d,%s\n",
			r.StartTime.Format(time.RFC3339),
			r.EndTime.Format(time.RFC3339),
			r.Duration.Milliseconds(),
			r.PromptTokens,
			r.CompletionTokens,
			r.TotalTokens,
			errorMsg)

		_, err = file.WriteString(row)
		if err != nil {
			return err
		}
	}

	return nil
}
