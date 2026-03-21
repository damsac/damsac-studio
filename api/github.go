package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
)

// ProjectData holds the fetched GitHub project board state.
type ProjectData struct {
	Title string
	Items []ProjectItem
}

// ProjectItem is a single item from the project board.
type ProjectItem struct {
	Title  string
	URL    string
	Status string
	Type   string // "Issue", "DraftIssue", "PullRequest"
}

const projectQuery = `query($org: String!, $number: Int!) {
  organization(login: $org) {
    projectV2(number: $number) {
      title
      items(first: 100) {
        nodes {
          content {
            __typename
            ... on Issue { title url }
            ... on DraftIssue { title }
            ... on PullRequest { title url }
          }
          fieldValueByName(name: "Status") {
            ... on ProjectV2ItemFieldSingleSelectValue { name }
          }
        }
      }
    }
  }
}`

// FetchProject fetches project board items from the GitHub GraphQL API.
func FetchProject(token, org string, number int) (*ProjectData, error) {
	body, err := json.Marshal(map[string]interface{}{
		"query": projectQuery,
		"variables": map[string]interface{}{
			"org":    org,
			"number": number,
		},
	})
	if err != nil {
		return nil, err
	}

	req, err := http.NewRequest("POST", "https://api.github.com/graphql", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		b, _ := io.ReadAll(resp.Body)
		return nil, fmt.Errorf("github api %d: %s", resp.StatusCode, b)
	}

	var result struct {
		Data struct {
			Organization struct {
				ProjectV2 struct {
					Title string `json:"title"`
					Items struct {
						Nodes []struct {
							Content struct {
								Typename string `json:"__typename"`
								Title    string `json:"title"`
								URL      string `json:"url"`
							} `json:"content"`
							FieldValueByName *struct {
								Name string `json:"name"`
							} `json:"fieldValueByName"`
						} `json:"nodes"`
					} `json:"items"`
				} `json:"projectV2"`
			} `json:"organization"`
		} `json:"data"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
		return nil, fmt.Errorf("decode: %w", err)
	}

	proj := result.Data.Organization.ProjectV2
	data := &ProjectData{Title: proj.Title}

	for _, node := range proj.Items.Nodes {
		if node.Content.Title == "" {
			continue
		}
		status := ""
		if node.FieldValueByName != nil {
			status = node.FieldValueByName.Name
		}
		data.Items = append(data.Items, ProjectItem{
			Title:  node.Content.Title,
			URL:    node.Content.URL,
			Status: status,
			Type:   node.Content.Typename,
		})
	}

	return data, nil
}
